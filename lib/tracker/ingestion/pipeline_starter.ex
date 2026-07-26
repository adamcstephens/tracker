defmodule Tracker.Ingestion.PipelineStarter do
  @moduledoc """
  Creates and starts ingestion pipelines.

  Provides a unified `sync_channel/2` entry point used by both the cron
  worker and manual backfills. Pipelines are created with predecessor
  links to enforce sequential execution.
  """

  alias Tracker.Ingestion.{IngestionRun, Pipeline, StepGraph, StepWorker}
  alias Tracker.Nixpkgs.{Channel, Release}

  @doc """
  Synchronises a channel by creating pipelines for any known releases that
  don't yet have one. Callers are expected to have refreshed the release
  ledger first (`Release.refresh/2`).

  Options:
    - `bootstrap` - when true, allows creating pipelines with no prior
      completed pipeline. Required for initial backfill. Default: false.
    - `after` - optional DateTime cutoff; only creates pipelines for
      releases newer than this. Only used with bootstrap.
    - `revision_resolver` - function to resolve full revision from release.
      Default: fetches from S3.
  """
  def sync_channel(%Channel{} = channel, opts \\ []) do
    bootstrap = Keyword.get(opts, :bootstrap, false)
    after_date = Keyword.get(opts, :after)
    resolver = Keyword.get(opts, :revision_resolver, &resolve_revision/1)

    # Find last completed pipeline's released_at
    last_completed =
      case Pipeline.last_completed_for_channel!(channel.id) do
        [pipeline] -> pipeline
        [] -> nil
      end

    new_releases =
      if !bootstrap and last_completed == nil do
        []
      else
        # Determine cutoff
        cutoff =
          cond do
            last_completed != nil -> last_completed.released_at
            after_date != nil -> after_date
            true -> nil
          end

        # Known releases (oldest first) without any pipeline, past cutoff
        Release.without_pipeline!(channel.id)
        |> Enum.filter(fn r -> cutoff == nil or DateTime.after?(r.released_at, cutoff) end)
      end

    if new_releases != [] do
      run_type = if bootstrap, do: :backfill, else: :cron_update
      run = IngestionRun.create!(%{type: run_type, started_at: DateTime.utc_now()})

      create_pipelines_with_predecessors(run, channel, new_releases, resolver)
    end

    # Always advance: a channel wedged behind a failed head has nothing new to
    # create but still needs its head re-driven.
    advance_channel(channel.id)

    if new_releases == [], do: :noop, else: {:ok, length(new_releases)}
  end

  @doc """
  Backfills a channel from scratch. Requires zero existing pipelines.

  Options:
    - `after` - optional DateTime; only ingest releases newer than this.
    - `revision_resolver` - function to resolve full revision from release.
  """
  def backfill_channel(%Channel{} = channel, opts \\ []) do
    existing = Pipeline.for_channel!(channel.id)

    if existing != [] do
      raise ArgumentError,
            "Cannot backfill channel #{channel.name}: #{length(existing)} pipelines already exist"
    end

    sync_channel(channel, Keyword.put(opts, :bootstrap, true))
  end

  @doc """
  Creates and starts a single pipeline for a channel revision.

  Returns the created pipeline.
  """
  def start_pipeline(run, attrs) do
    active_steps = StepGraph.steps_for(attrs.channel_name)

    pipeline =
      Pipeline.create!(
        Map.merge(attrs, %{
          active_steps: active_steps,
          ingestion_run_id: run.id
        })
      )

    Pipeline.start!(pipeline)
    StepWorker.enqueue(pipeline, :create_revision)

    pipeline
  end

  @doc """
  Retries a failed or stuck pipeline from its failed step.

  Operator entry point: resets the auto-retry budget and lifts `:stuck`, on the
  assumption the caller has fixed the cause.
  """
  def retry_pipeline(pipeline) do
    unless pipeline.status in [:failed, :stuck] do
      raise ArgumentError, "Can only retry failed or stuck pipelines, got #{pipeline.status}"
    end

    pipeline
    |> Pipeline.clear_retries!()
    |> restart_from_failed_step()
  end

  # -- Private --

  defp create_pipelines_with_predecessors(run, channel, releases, resolver) do
    active_steps = StepGraph.steps_for(channel.name)

    # Track created pipelines by revision for intra-batch predecessor lookup
    releases
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {release, index}, created_map ->
      revision = release.revision || resolve_and_store(release, resolver)

      predecessor_id = resolve_predecessor_id(channel, release, created_map)

      pipeline =
        Pipeline.create!(%{
          channel_id: channel.id,
          revision: revision,
          base_url: release.base_url,
          released_at: release.released_at,
          active_steps: active_steps,
          sequence: index,
          ingestion_run_id: run.id,
          predecessor_id: predecessor_id
        })

      Map.put(created_map, revision, pipeline)
    end)
  end

  defp resolve_and_store(release, resolver) do
    revision = release |> resolver.() |> String.trim()
    Release.resolve!(release, revision)
    revision
  end

  defp resolve_predecessor_id(channel, release, created_map) do
    case Release.previous_before!(channel.id, release.released_at) do
      nil ->
        nil

      prev_release ->
        # Check if we just created it in this batch
        case Map.get(created_map, prev_release.revision) do
          %Pipeline{id: id} ->
            id

          nil ->
            # Look up in DB by exact revision
            find_pipeline_by_revision(channel.id, prev_release.revision)
        end
    end
  end

  defp find_pipeline_by_revision(_channel_id, nil), do: nil

  defp find_pipeline_by_revision(channel_id, revision) do
    case Pipeline.find(channel_id, revision) do
      {:ok, %Pipeline{id: id}} -> id
      _ -> nil
    end
  end

  # Drives the chain head forward. `:stuck` and `:running` heads are left alone —
  # the first is terminal until an operator intervenes, the second is in flight.
  defp advance_channel(channel_id) do
    case Pipeline.oldest_incomplete_for_channel(channel_id) do
      {:ok, %Pipeline{status: :pending} = head} ->
        if startable?(head) do
          Pipeline.start!(head)
          StepWorker.enqueue(head, :create_revision)
        end

      {:ok, %Pipeline{status: :failed} = head} ->
        restart_from_failed_step(head)

      _ ->
        :ok
    end
  end

  defp restart_from_failed_step(pipeline) do
    failed_step = pipeline.failed_step

    Pipeline.retry_from_step!(pipeline)

    StepWorker.enqueue(pipeline, failed_step)

    :ok
  end

  defp startable?(pipeline) do
    case pipeline.predecessor_id do
      nil ->
        true

      predecessor_id ->
        case Ash.get(Pipeline, predecessor_id) do
          {:ok, %{status: :completed}} -> true
          _ -> false
        end
    end
  end

  defp resolve_revision(release) do
    Req.get!(Tracker.Nixpkgs.S3Cache.new(), url: release.base_url <> "/git-revision").body
  end
end

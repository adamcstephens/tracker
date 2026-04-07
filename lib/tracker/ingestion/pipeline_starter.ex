defmodule Tracker.Ingestion.PipelineStarter do
  @moduledoc """
  Creates and starts ingestion pipelines.

  Provides a unified `sync_channel/2` entry point used by both the cron
  worker and manual backfills. Pipelines are created with predecessor
  links to enforce sequential execution.
  """

  require Logger

  alias Tracker.Ingestion.{IngestionRun, Pipeline, StepGraph, StepWorker}
  alias Tracker.Nixpkgs.ReleaseCache

  @doc """
  Synchronises a channel by creating pipelines for any releases in the
  ReleaseCache that don't yet have one.

  Options:
    - `bootstrap` - when true, allows creating pipelines with no prior
      completed pipeline. Required for initial backfill. Default: false.
    - `after` - optional DateTime cutoff; only creates pipelines for
      releases newer than this. Only used with bootstrap.
    - `cache` - ReleaseCache server name. Default: ReleaseCache.
    - `revision_resolver` - function to resolve full revision from release.
      Default: fetches from S3.
  """
  def sync_channel(channel, opts \\ []) do
    bootstrap = Keyword.get(opts, :bootstrap, false)
    after_date = Keyword.get(opts, :after)
    cache = Keyword.get(opts, :cache, ReleaseCache)
    resolver = Keyword.get(opts, :revision_resolver, &resolve_revision/1)

    # Get releases oldest-first
    releases = ReleaseCache.get_releases(cache, channel) |> Enum.sort_by(& &1.released_at, :asc)

    # Find last completed pipeline's released_at
    last_completed =
      case Pipeline.last_completed_for_channel!(channel) do
        [pipeline] -> pipeline
        [] -> nil
      end

    # If not bootstrap and no completed pipeline, nothing to do
    if !bootstrap and last_completed == nil do
      :noop
    else
      # Determine cutoff
      cutoff =
        cond do
          last_completed != nil -> last_completed.released_at
          after_date != nil -> after_date
          true -> nil
        end

      # Filter releases newer than cutoff
      target_releases =
        if cutoff do
          cutoff_str = DateTime.to_iso8601(cutoff)
          Enum.filter(releases, fn r -> r.released_at > cutoff_str end)
        else
          releases
        end

      # Exclude releases with existing non-failed pipelines
      new_releases = filter_missing_releases(target_releases, channel)

      if new_releases == [] do
        :noop
      else
        run_type = if bootstrap, do: :backfill, else: :cron_update
        run = IngestionRun.create!(%{type: run_type, started_at: DateTime.utc_now()})

        create_pipelines_with_predecessors(run, channel, new_releases, cache, resolver)

        start_first_startable(channel)

        {:ok, length(new_releases)}
      end
    end
  end

  @doc """
  Backfills a channel from scratch. Requires zero existing pipelines.

  Options:
    - `after` - optional DateTime; only ingest releases newer than this.
    - `cache` - ReleaseCache server name.
    - `revision_resolver` - function to resolve full revision from release.
  """
  def backfill_channel(channel, opts \\ []) do
    existing = Pipeline.for_channel!(channel)

    if existing != [] do
      raise ArgumentError,
            "Cannot backfill channel #{channel}: #{length(existing)} pipelines already exist"
    end

    sync_channel(channel, Keyword.put(opts, :bootstrap, true))
  end

  @doc """
  Creates and starts a single pipeline for a channel revision.

  Returns the created pipeline.
  """
  def start_pipeline(run, attrs) do
    active_steps = StepGraph.steps_for(attrs.channel)

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
  Retries a failed pipeline from its failed step.
  """
  def retry_pipeline(pipeline) do
    unless pipeline.status == :failed do
      raise ArgumentError, "Can only retry failed pipelines, got #{pipeline.status}"
    end

    failed_step = pipeline.failed_step

    Pipeline.retry_from_step!(pipeline)

    StepWorker.enqueue(pipeline, failed_step)

    :ok
  end

  # -- Private --

  defp create_pipelines_with_predecessors(run, channel, releases, cache, resolver) do
    active_steps = StepGraph.steps_for(channel)

    # Track created pipelines by short_hash for intra-batch predecessor lookup
    releases
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {release, index}, created_map ->
      revision = resolver.(release)

      # Find predecessor: look in ReleaseCache for the previous release
      predecessor_id = resolve_predecessor_id(channel, release.short_hash, cache, created_map)

      pipeline =
        Pipeline.create!(%{
          channel: channel,
          revision: revision,
          base_url: release.base_url,
          released_at: parse_released_at(release.released_at),
          active_steps: active_steps,
          sequence: index,
          ingestion_run_id: run.id,
          predecessor_id: predecessor_id
        })

      Map.put(created_map, release.short_hash, pipeline)
    end)
  end

  defp resolve_predecessor_id(channel, short_hash, cache, created_map) do
    case ReleaseCache.find_previous_release(cache, channel, short_hash) do
      nil ->
        nil

      prev_release ->
        # Check if we just created it in this batch
        case Map.get(created_map, prev_release.short_hash) do
          %Pipeline{id: id} ->
            id

          nil ->
            # Look up in DB by short_hash prefix
            find_pipeline_by_short_hash(channel, prev_release.short_hash)
        end
    end
  end

  defp find_pipeline_by_short_hash(channel, short_hash) do
    case Pipeline.for_channel!(channel) do
      pipelines ->
        case Enum.find(pipelines, fn p -> String.starts_with?(p.revision, short_hash) end) do
          %Pipeline{id: id} -> id
          nil -> nil
        end
    end
  end

  defp filter_missing_releases(releases, channel) do
    existing =
      Pipeline.for_channel!(channel)
      |> Enum.filter(&(&1.status != :failed))
      |> MapSet.new(& &1.revision)

    Enum.reject(releases, fn release ->
      Enum.any?(existing, &String.starts_with?(&1, release.short_hash))
    end)
  end

  defp start_first_startable(channel) do
    case Pipeline.next_pending_for_channel!(channel) do
      [next | _] ->
        if startable?(next) do
          Pipeline.start!(next)
          StepWorker.enqueue(next, :create_revision)
        end

      [] ->
        :ok
    end
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

  defp parse_released_at(released_at) when is_binary(released_at) do
    case DateTime.from_iso8601(released_at) do
      {:ok, dt, _offset} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp parse_released_at(%DateTime{} = dt), do: dt
end

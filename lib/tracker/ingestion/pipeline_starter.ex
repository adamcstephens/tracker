defmodule Tracker.Ingestion.PipelineStarter do
  @moduledoc """
  Creates and starts ingestion pipelines.

  Provides entry points for cron updates, backfills, full reloads,
  and retrying failed pipelines.
  """

  require Logger

  alias Tracker.Ingestion.{IngestionRun, Pipeline, StepGraph, StepWorker}
  alias Tracker.Nixpkgs.{Channel, ReleaseCache}

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
  Creates a cron update for a single channel.

  Resolves the latest revision, skips if already ingested,
  otherwise creates an IngestionRun + Pipeline and starts it.
  """
  def start_cron_update(channel) do
    {revision, base_url} = Channel.get_channel_revision(channel)
    released_at = resolve_released_at(channel, base_url)

    case Pipeline.find(channel, revision) do
      {:ok, %Pipeline{status: status}} when status != :failed ->
        Logger.info(
          "Pipeline for #{channel}@#{String.slice(revision, 0, 7)} already exists (#{status}), skipping"
        )

        :already_exists

      _ ->
        run = IngestionRun.create!(%{type: :cron_update, started_at: DateTime.utc_now()})

        start_pipeline(run, %{
          channel: channel,
          revision: revision,
          base_url: base_url,
          released_at: released_at,
          sequence: 0
        })

        :ok
    end
  end

  @doc """
  Creates pipelines for all configured channels' historical releases.

  Channels process in parallel, revisions within a channel process
  sequentially (ordered by sequence number, oldest first).
  """
  def reload_all do
    channels = Application.get_env(:tracker, :channels, [])
    run = IngestionRun.create!(%{type: :reload, started_at: DateTime.utc_now()})

    total =
      channels
      |> Enum.map(fn channel ->
        create_pipelines_for_channel(run, channel)
      end)
      |> Enum.sum()

    if total == 0 do
      IngestionRun.mark_completed!(run)
      {:ok, 0}
    else
      # Start the first pending pipeline per channel
      channels
      |> Enum.each(fn channel ->
        case Pipeline.next_pending_for_channel!(channel) do
          [first | _] ->
            Pipeline.start!(first)
            StepWorker.enqueue(first, :create_revision)

          [] ->
            :ok
        end
      end)

      {:ok, total}
    end
  end

  @doc """
  Creates pipelines for a single channel's historical releases.
  """
  def backfill_channel(channel, opts \\ []) do
    limit = Keyword.get(opts, :limit)
    run = IngestionRun.create!(%{type: :backfill, started_at: DateTime.utc_now()})

    total = create_pipelines_for_channel(run, channel, limit: limit)

    if total == 0 do
      IngestionRun.mark_completed!(run)
      {:ok, 0}
    else
      case Pipeline.next_pending_for_channel!(channel) do
        [first | _] ->
          Pipeline.start!(first)
          StepWorker.enqueue(first, :create_revision)

        [] ->
          :ok
      end

      {:ok, total}
    end
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

  defp create_pipelines_for_channel(run, channel, opts \\ []) do
    limit = Keyword.get(opts, :limit)

    releases =
      ReleaseCache.get_releases(channel)
      |> Enum.reverse()
      |> filter_existing_pipelines(channel)

    releases = if limit, do: Enum.take(releases, limit), else: releases

    releases
    |> Enum.with_index()
    |> Enum.each(fn {release, index} ->
      Pipeline.create!(%{
        channel: channel,
        revision: resolve_revision(release),
        base_url: release.base_url,
        released_at: release.released_at,
        active_steps: StepGraph.steps_for(channel),
        sequence: index,
        ingestion_run_id: run.id
      })
    end)

    length(releases)
  end

  defp filter_existing_pipelines(releases, channel) do
    existing =
      Pipeline.read!()
      |> Enum.filter(&(&1.channel == channel and &1.status != :failed))
      |> MapSet.new(& &1.revision)

    Enum.reject(releases, fn release ->
      Enum.any?(existing, &String.starts_with?(&1, release.short_hash))
    end)
  end

  defp resolve_revision(release) do
    Req.get!(Tracker.Nixpkgs.S3Cache.new(), url: release.base_url <> "/git-revision").body
  end

  defp resolve_released_at(channel, base_url) do
    case ReleaseCache.find_by_base_url(channel, base_url) do
      %{released_at: released_at} -> released_at
      nil -> DateTime.utc_now()
    end
  end
end

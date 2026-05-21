defmodule Tracker.Nixpkgs.HydraStatusFetcher do
  @moduledoc """
  Polls `Tracker.Hydra.Client` and projects the latest build/status state
  onto matching `Tracker.Nixpkgs.Channel` rows.

  Runs on a 5-minute cron. Channels present in our DB but missing from
  the Prometheus response are left untouched (their previously stored
  values remain — the next successful poll updates them). Channels in
  the Prometheus response but unknown to us are silently skipped.
  """
  use Oban.Worker, queue: :ingestion, max_attempts: 3, unique: [period: 60]

  require Logger

  alias Tracker.Hydra.Client
  alias Tracker.Nixpkgs.Channel

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case run() do
      {:ok, _} ->
        :ok

      {:error, reason} = err ->
        Logger.warning(msg: "hydra status fetch failed", reason: inspect(reason)) && err
    end
  end

  @doc """
  Runs one fetch+upsert cycle.

  Options (test-only):
    * `:fetch` — zero-arity function returning
      `{:ok, [%ChannelStatus{}], [%BuildFailure{}]}` or `{:error, term}`.
  """
  def run(opts \\ []) do
    fetch = Keyword.get(opts, :fetch, &default_fetch/0)

    with {:ok, _channel_statuses, build_failures} <- fetch.() do
      failures_by_channel = Map.new(build_failures, &{&1.channel, &1})

      {updated, skipped} =
        Enum.reduce(failures_by_channel, {0, 0}, fn {channel_name, failure}, {u, s} ->
          case Channel.by_name(channel_name) do
            {:ok, channel} ->
              if changed?(channel, failure) do
                {:ok, _} =
                  Channel.update_hydra_status(channel, %{
                    hydra_build_failed?: failure.failed?,
                    hydra_project: failure.project,
                    hydra_jobset: failure.jobset,
                    hydra_exported_job: failure.exported_job
                  })

                {u + 1, s}
              else
                {u, s + 1}
              end

            {:error, _} ->
              {u, s + 1}
          end
        end)

      Logger.info(msg: "hydra status fetch complete", updated: updated, skipped: skipped)
      {:ok, %{updated: updated, skipped: skipped}}
    end
  end

  defp changed?(channel, failure) do
    channel.hydra_build_failed? != failure.failed? or
      channel.hydra_project != failure.project or
      channel.hydra_jobset != failure.jobset or
      channel.hydra_exported_job != failure.exported_job
  end

  defp default_fetch do
    with {:ok, channel_statuses} <- Client.fetch_channel_status(),
         {:ok, build_failures} <- Client.fetch_build_failures() do
      {:ok, channel_statuses, build_failures}
    end
  end
end

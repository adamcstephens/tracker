defmodule Tracker.Ingestion.CronWorker do
  @moduledoc """
  Thin Oban cron worker that triggers channel synchronisation
  for configured channels.
  """

  use Oban.Worker, queue: :ingestion, max_attempts: 3

  require Logger

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(2)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"channel" => channel_name}}) do
    {:ok, channel} = Tracker.Nixpkgs.Channel.by_name(channel_name)

    case Tracker.Ingestion.PipelineStarter.sync_channel(channel) do
      {:ok, count} ->
        Logger.info("Synced #{channel_name}: created #{count} pipeline(s)")

      :noop ->
        Logger.debug("Synced #{channel_name}: no new revisions")
    end

    :ok
  end
end

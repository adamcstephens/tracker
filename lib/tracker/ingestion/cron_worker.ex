defmodule Tracker.Ingestion.CronWorker do
  @moduledoc """
  Oban cron worker that synchronises all active channels from the database.
  """

  use Oban.Worker, queue: :ingestion, max_attempts: 3

  require Logger

  alias Tracker.Nixpkgs.Channel

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(2)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    channels = Channel.active!()

    Enum.each(channels, fn channel ->
      case Tracker.Ingestion.PipelineStarter.sync_channel(channel) do
        {:ok, count} ->
          Logger.info("Synced #{channel.name}: created #{count} pipeline(s)")

        :noop ->
          Logger.debug("Synced #{channel.name}: no new revisions")
      end
    end)

    :ok
  end
end

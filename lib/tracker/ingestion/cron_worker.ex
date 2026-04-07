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
  def perform(%Oban.Job{args: %{"channel" => channel}}) do
    case Tracker.Ingestion.PipelineStarter.sync_channel(channel) do
      {:ok, count} ->
        Logger.info("Synced #{channel}: created #{count} pipeline(s)")

      :noop ->
        Logger.debug("Synced #{channel}: no new revisions")
    end

    :ok
  end
end

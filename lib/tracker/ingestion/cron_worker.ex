defmodule Tracker.Ingestion.CronWorker do
  @moduledoc """
  Thin Oban cron worker that triggers ingestion pipeline updates
  for configured channels.

  Replaces ChannelWorker's cron entries with pipeline-based execution.
  """

  use Oban.Worker, queue: :ingestion, max_attempts: 3

  require Logger

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(2)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"channel" => channel}}) do
    result = Tracker.Ingestion.PipelineStarter.start_cron_update(channel)

    case result do
      :ok ->
        Logger.info("Started ingestion pipeline for #{channel}")

      :already_exists ->
        :ok
    end

    :ok
  end
end

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
    Logger.info(msg: "ingestion cron started", active_channels: length(channels))
    started_at = System.monotonic_time()

    {created, noop} =
      Enum.reduce(channels, {0, 0}, fn channel, {created, noop} ->
        case Tracker.Ingestion.PipelineStarter.sync_channel(channel) do
          {:ok, count} ->
            Logger.debug(msg: "channel synced", channel: channel.name, created: count)
            {created + count, noop}

          :noop ->
            Logger.debug(msg: "channel noop", channel: channel.name)
            {created, noop + 1}
        end
      end)

    Logger.info(
      msg: "ingestion cron finished",
      outcome: :ok,
      synced: length(channels),
      created: created,
      noop: noop,
      duration_ms: duration_ms(started_at)
    )

    :ok
  end

  defp duration_ms(started_at) do
    System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)
  end
end

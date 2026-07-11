defmodule Tracker.Ingestion.CronWorker do
  @moduledoc """
  Lightweight per-channel poller.

  For each active channel, issues a conditional GET against
  `https://channels.nixos.org/<channel>/git-revision`. On `304` the worker
  does nothing. On `200` it stores the new ETag/Last-Modified pointer on the
  channel and, if no non-failed ingestion pipeline exists for that revision
  yet, refreshes the channel's release ledger and runs
  `PipelineStarter.sync_channel/1`.
  """

  use Oban.Worker, queue: :ingestion, max_attempts: 3

  require Logger

  alias Tracker.Ingestion.{Pipeline, PipelineStarter}
  alias Tracker.Nixpkgs.{Channel, Release}

  @pointer_base_url "https://channels.nixos.org"

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(2)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    channels = Channel.active!()
    Logger.info(msg: "channel poll started", active_channels: length(channels))
    started_at = System.monotonic_time()

    counts =
      Enum.reduce(channels, %{unchanged: 0, changed: 0, synced: 0, created: 0}, fn channel, acc ->
        poll_channel(channel, acc)
      end)

    Logger.info(
      msg: "channel poll finished",
      outcome: :ok,
      active_channels: length(channels),
      unchanged: counts.unchanged,
      changed: counts.changed,
      synced: counts.synced,
      created: counts.created,
      duration_ms: duration_ms(started_at)
    )

    :ok
  end

  defp poll_channel(channel, acc) do
    case fetch_pointer(channel) do
      {:not_modified, _resp} ->
        maybe_sync(channel, channel.pointer_revision, :not_modified, acc)

      {:ok, pointer} ->
        channel = Channel.put_pointer!(channel, pointer)
        maybe_sync(channel, channel.pointer_revision, :same_revision, acc)

      {:error, reason} ->
        Logger.warning(msg: "channel poll error", channel: channel.name, reason: inspect(reason))
        acc
    end
  end

  defp maybe_sync(channel, revision, unchanged_reason, acc) do
    if revision != nil and not pipeline_exists?(channel.id, revision) do
      sync_after_pointer_change(channel, %{acc | changed: acc.changed + 1})
    else
      Logger.debug(msg: "channel poll unchanged", channel: channel.name, reason: unchanged_reason)
      %{acc | unchanged: acc.unchanged + 1}
    end
  end

  defp pipeline_exists?(channel_id, revision) do
    case Pipeline.find(channel_id, revision) do
      {:ok, %Pipeline{status: :failed}} -> false
      {:ok, %Pipeline{}} -> true
      _ -> false
    end
  end

  defp sync_after_pointer_change(channel, acc) do
    :ok = Release.refresh(channel, releases_fetcher_opt())

    case PipelineStarter.sync_channel(channel) do
      {:ok, count} ->
        Logger.info(msg: "channel synced", channel: channel.name, created: count)
        %{acc | synced: acc.synced + 1, created: acc.created + count}

      :noop ->
        %{acc | synced: acc.synced + 1}
    end
  end

  defp fetch_pointer(channel) do
    headers = conditional_headers(channel)

    req =
      Keyword.merge(
        [
          url: "#{@pointer_base_url}/#{channel.name}/git-revision",
          headers: headers
        ],
        req_options()
      )
      |> Req.new()

    case Req.get(req) do
      {:ok, %Req.Response{status: 304} = resp} ->
        {:not_modified, resp}

      {:ok, %Req.Response{status: 200} = resp} ->
        {:ok, pointer_from_response(resp)}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp conditional_headers(channel) do
    []
    |> add_header("if-none-match", channel.pointer_etag)
    |> add_header("if-modified-since", channel.pointer_last_modified)
  end

  defp add_header(headers, _name, nil), do: headers
  defp add_header(headers, name, value), do: [{name, value} | headers]

  defp pointer_from_response(%Req.Response{} = resp) do
    %{
      pointer_etag: header(resp, "etag"),
      pointer_last_modified: header(resp, "last-modified"),
      pointer_revision: revision_from_body(resp.body)
    }
  end

  defp header(%Req.Response{} = resp, name) do
    case Req.Response.get_header(resp, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp revision_from_body(body) when is_binary(body) do
    case String.trim(body) do
      "" -> nil
      rev -> rev
    end
  end

  defp revision_from_body(_), do: nil

  defp req_options do
    Application.get_env(:tracker, :channel_pointer_req_options, [])
  end

  defp releases_fetcher_opt do
    case Application.get_env(:tracker, :releases_fetcher) do
      nil -> []
      fun when is_function(fun, 1) -> [releases_fetcher: fun]
    end
  end

  defp duration_ms(started_at) do
    System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)
  end
end

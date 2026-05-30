defmodule Tracker.Ingestion.CronWorker do
  @moduledoc """
  Lightweight per-channel poller.

  For each active channel, issues a conditional GET against
  `https://channels.nixos.org/<channel>/git-revision`. On `304` the worker
  does nothing. On `200` it stores the new ETag/Last-Modified pointer and,
  if no non-failed ingestion pipeline exists for that revision yet,
  refreshes the channel's S3 listing and runs
  `PipelineStarter.sync_channel/1`.
  """

  use Oban.Worker, queue: :ingestion, max_attempts: 3

  require Logger

  alias Tracker.Ingestion.{Pipeline, PipelineStarter}
  alias Tracker.Nixpkgs.{Channel, ReleaseCache}

  @pointer_base_url "https://channels.nixos.org"

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(2)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    channels = Channel.active!()
    Logger.info(msg: "channel poll started", active_channels: length(channels))
    started_at = System.monotonic_time()

    cache = cache_name()

    counts =
      Enum.reduce(channels, %{unchanged: 0, changed: 0, synced: 0, created: 0}, fn channel, acc ->
        poll_channel(channel, cache, acc)
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

  defp poll_channel(channel, cache, acc) do
    pointer = ReleaseCache.get_pointer(cache, channel.name)

    case fetch_pointer(channel.name, pointer) do
      {:not_modified, _resp} ->
        maybe_sync(channel, cache, pointer_revision(pointer), :not_modified, acc)

      {:ok, new_pointer} ->
        ReleaseCache.put_pointer(cache, channel.name, new_pointer)
        maybe_sync(channel, cache, new_pointer.revision, :same_revision, acc)

      {:error, reason} ->
        Logger.warning(msg: "channel poll error", channel: channel.name, reason: inspect(reason))
        acc
    end
  end

  defp maybe_sync(channel, cache, revision, unchanged_reason, acc) do
    if revision != nil and not pipeline_exists?(channel.id, revision) do
      sync_after_pointer_change(channel, cache, %{acc | changed: acc.changed + 1})
    else
      Logger.debug(msg: "channel poll unchanged", channel: channel.name, reason: unchanged_reason)
      %{acc | unchanged: acc.unchanged + 1}
    end
  end

  defp pointer_revision(nil), do: nil
  defp pointer_revision(%{revision: revision}), do: revision

  defp pipeline_exists?(channel_id, revision) do
    case Pipeline.find(channel_id, revision) do
      {:ok, %Pipeline{status: :failed}} -> false
      {:ok, %Pipeline{}} -> true
      _ -> false
    end
  end

  defp sync_after_pointer_change(channel, cache, acc) do
    ReleaseCache.refresh_channel(cache, channel.name, releases_fetcher_opt())

    case PipelineStarter.sync_channel(channel, cache: cache) do
      {:ok, count} ->
        Logger.info(msg: "channel synced", channel: channel.name, created: count)
        %{acc | synced: acc.synced + 1, created: acc.created + count}

      :noop ->
        %{acc | synced: acc.synced + 1}
    end
  end

  defp fetch_pointer(channel_name, pointer) do
    headers = conditional_headers(pointer)

    req =
      Keyword.merge(
        [
          url: "#{@pointer_base_url}/#{channel_name}/git-revision",
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

  defp conditional_headers(nil), do: []

  defp conditional_headers(%{etag: etag, last_modified: lm}) do
    []
    |> add_header("if-none-match", etag)
    |> add_header("if-modified-since", lm)
  end

  defp add_header(headers, _name, nil), do: headers
  defp add_header(headers, name, value), do: [{name, value} | headers]

  defp pointer_from_response(%Req.Response{} = resp) do
    %{
      etag: header(resp, "etag"),
      last_modified: header(resp, "last-modified"),
      revision: revision_from_body(resp.body)
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

  defp cache_name do
    Application.get_env(:tracker, :release_cache_name, ReleaseCache)
  end

  defp req_options do
    Application.get_env(:tracker, :channel_pointer_req_options, [])
  end

  defp releases_fetcher_opt do
    case Application.get_env(:tracker, :release_cache_fetcher) do
      nil -> []
      fun when is_function(fun, 1) -> [releases_fetcher: fun]
    end
  end

  defp duration_ms(started_at) do
    System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)
  end
end

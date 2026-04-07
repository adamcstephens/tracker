defmodule Tracker.Nixpkgs.ReleaseCache do
  @moduledoc """
  In-memory cache of S3 release listings for all configured channels.

  Periodically polls the nix-releases S3 bucket and stores parsed release
  entries per channel, sorted by `released_at` desc (newest first).

  Refreshes happen asynchronously in a background task so reads never
  block on S3 fetches.
  """

  use GenServer

  require Logger

  alias Tracker.Nixpkgs.ReleaseCache.Release

  @releases_base_url "https://releases.nixos.org"

  # Oldest release date we'll ingest. packages.json.br was introduced around
  # 2020-03-27 02:16:34 (first seen on nixos-unstable-small), but we default
  # to 2025-01-01 for now.
  @release_cutoff_date "2025-01-01T00:00:00"

  defmodule Release do
    use TypedStruct

    typedstruct enforce: true do
      field :short_hash, String.t()
      field :base_url, String.t()
      field :released_at, String.t()
    end
  end

  # Public API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def get_releases(server \\ __MODULE__, channel) do
    case GenServer.call(server, {:get_releases, channel}) do
      [] ->
        releases =
          channel
          |> fetch_releases()
          |> parse_releases()

        GenServer.call(server, {:put_releases, channel, releases})
        releases

      releases ->
        releases
    end
  end

  def find_previous_release(server \\ __MODULE__, channel, short_hash) do
    GenServer.call(server, {:find_previous_release, channel, short_hash})
  end

  def find_by_base_url(server \\ __MODULE__, channel, base_url) do
    GenServer.call(server, {:find_by_base_url, channel, base_url})
  end

  def find_by_revision(server \\ __MODULE__, channel, revision) do
    GenServer.call(server, {:find_by_revision, channel, revision})
  end

  def refresh(server \\ __MODULE__) do
    GenServer.cast(server, :refresh)
  end

  def put_releases(server \\ __MODULE__, channel, releases) do
    GenServer.call(server, {:put_releases, channel, releases})
  end

  # S3 listing (extracted from ChannelWorker)

  @doc """
  Returns the full cached state: a map of channel name to release list.
  """
  def list_releases(server \\ __MODULE__) do
    GenServer.call(server, :list_releases)
  end

  @doc false
  def parse_releases(contents) do
    contents
    |> List.wrap()
    |> Enum.map(fn %{"Key" => key, "LastModified" => last_modified} ->
      short_hash = key |> String.split(".") |> List.last()

      %Release{
        short_hash: short_hash,
        base_url: "#{@releases_base_url}/#{key}",
        released_at: last_modified
      }
    end)
    |> Enum.reject(fn release -> release.released_at < @release_cutoff_date end)
    |> Enum.sort_by(& &1.released_at, :desc)
  end

  defp channel_to_s3_prefix("nixos-" <> rest), do: "nixos/#{rest}/"
  defp channel_to_s3_prefix("nixpkgs-" <> rest), do: "nixpkgs/#{rest}/"
  defp channel_to_s3_prefix(channel), do: "#{channel}/"

  defp fetch_releases(channel) do
    req_s3 = Req.new() |> ReqS3.attach()
    fetch_releases(req_s3, channel, nil, [])
  end

  # GenServer callbacks

  @impl GenServer
  def init(opts) do
    load? =
      Keyword.get(opts, :load, Application.get_env(:tracker, :release_cache_load, true))

    if load? do
      {:ok, %{releases: %{}, refreshing: false}, {:continue, :load}}
    else
      {:ok, %{releases: %{}, refreshing: false}}
    end
  end

  @impl GenServer
  def handle_continue(:load, state) do
    {:noreply, start_async_refresh(state)}
  end

  @impl GenServer
  def handle_info(:refresh, state) do
    {:noreply, start_async_refresh(state)}
  end

  def handle_info({:refresh_complete, new_releases}, state) do
    {:noreply, %{state | releases: new_releases, refreshing: false}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, :normal}, state) do
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.error("ReleaseCache refresh task failed: #{inspect(reason)}")
    {:noreply, %{state | refreshing: false}}
  end

  @impl GenServer
  def handle_cast(:refresh, state) do
    {:noreply, start_async_refresh(state)}
  end

  @impl GenServer
  def handle_call(:list_releases, _from, state) do
    {:reply, state.releases, state}
  end

  def handle_call({:get_releases, channel}, _from, state) do
    {:reply, Map.get(state.releases, channel, []), state}
  end

  def handle_call({:find_previous_release, channel, revision}, _from, state) do
    releases = Map.get(state.releases, channel, [])

    result =
      case Enum.find_index(releases, &String.starts_with?(revision, &1.short_hash)) do
        nil -> nil
        index -> Enum.at(releases, index + 1)
      end

    {:reply, result, state}
  end

  def handle_call({:find_by_revision, channel, revision}, _from, state) do
    release =
      state.releases
      |> Map.get(channel, [])
      |> Enum.find(&String.starts_with?(revision, &1.short_hash))

    {:reply, release, state}
  end

  def handle_call({:find_by_base_url, channel, base_url}, _from, state) do
    release =
      state.releases
      |> Map.get(channel, [])
      |> Enum.find(&(&1.base_url == base_url))

    {:reply, release, state}
  end

  def handle_call({:put_releases, channel, releases}, _from, state) do
    {:reply, :ok, %{state | releases: Map.put(state.releases, channel, releases)}}
  end

  # Private

  defp start_async_refresh(state) do
    if state.refreshing do
      state
    else
      server = self()

      Task.start(fn ->
        new_releases = do_refresh(state.releases)
        send(server, {:refresh_complete, new_releases})
      end)

      schedule_refresh()
      %{state | refreshing: true}
    end
  end

  defp do_refresh(current_releases) do
    active_names =
      Tracker.Nixpkgs.Channel.active!()
      |> Enum.map(& &1.name)

    all_channels = Enum.uniq(active_names ++ Map.keys(current_releases))

    Map.new(all_channels, fn channel ->
      releases =
        channel
        |> fetch_releases()
        |> parse_releases()

      {channel, releases}
    end)
  end

  defp fetch_releases(req_s3, channel, marker, acc) do
    params =
      [delimiter: "/", prefix: channel_to_s3_prefix(channel)]
      |> then(fn p -> if marker, do: Keyword.put(p, :marker, marker), else: p end)

    resp = Req.get!(req_s3, url: "s3://nix-releases", params: params)
    body = resp.body["ListBucketResult"]
    contents = body["Contents"] |> List.wrap()

    all_contents = acc ++ contents

    if body["IsTruncated"] == "true" do
      fetch_releases(req_s3, channel, body["NextMarker"], all_contents)
    else
      all_contents
    end
  end

  defp schedule_refresh do
    interval = Application.get_env(:tracker, :release_cache_interval, :timer.hours(1))
    Process.send_after(self(), :refresh, interval)
  end
end

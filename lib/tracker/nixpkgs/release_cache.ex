defmodule Tracker.Nixpkgs.ReleaseCache do
  @moduledoc """
  In-memory cache of S3 release listings for all configured channels.

  Periodically polls the nix-releases S3 bucket and stores parsed release
  entries per channel, sorted by `released_at` desc (newest first).
  """

  use GenServer

  alias Tracker.Nixpkgs.ReleaseCache.Release

  @releases_base_url "https://releases.nixos.org"

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

  defp parse_releases(contents) do
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
    |> Enum.sort_by(& &1.released_at, :desc)
  end

  defp channel_to_s3_prefix("nixos-" <> rest), do: "nixos/#{rest}/"
  defp channel_to_s3_prefix("nixpkgs-" <> rest), do: "nixpkgs/#{rest}/"
  defp channel_to_s3_prefix(channel), do: "#{channel}/"

  defp fetch_releases(channel) do
    req_s3 = req() |> ReqS3.attach()
    fetch_releases(req_s3, channel, nil, [])
  end

  # GenServer callbacks

  @impl GenServer
  def init(opts) do
    load? =
      Keyword.get(opts, :load, Application.get_env(:tracker, :release_cache_load, true))

    if load? do
      {:ok, %{}, {:continue, :load}}
    else
      {:ok, %{}}
    end
  end

  @impl GenServer
  def handle_continue(:load, state) do
    state = refresh_channels(state)
    schedule_refresh()
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:refresh, state) do
    state = refresh_channels(state)
    schedule_refresh()
    {:noreply, state}
  end

  @impl GenServer
  def handle_cast(:refresh, state) do
    {:noreply, refresh_channels(state)}
  end

  @impl GenServer
  def handle_call(:list_releases, _from, state) do
    {:reply, state, state}
  end

  def handle_call({:get_releases, channel}, _from, state) do
    {:reply, Map.get(state, channel, []), state}
  end

  def handle_call({:find_previous_release, channel, short_hash}, _from, state) do
    releases = Map.get(state, channel, [])

    result =
      case Enum.find_index(releases, &(&1.short_hash == short_hash)) do
        nil -> nil
        index -> Enum.at(releases, index + 1)
      end

    {:reply, result, state}
  end

  def handle_call({:put_releases, channel, releases}, _from, state) do
    {:reply, :ok, Map.put(state, channel, releases)}
  end

  # Private

  defp refresh_channels(state) do
    configured = Application.get_env(:tracker, :channels, [])
    all_channels = Enum.uniq(configured ++ Map.keys(state))

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

  defp req do
    if Application.get_env(:tracker, :http_cache, false) do
      cache_dir = Application.get_env(:tracker, :cache_dir, "_build/releases_cache")
      Req.new(cache: true, cache_dir: cache_dir)
    else
      Req.new()
    end
  end
end

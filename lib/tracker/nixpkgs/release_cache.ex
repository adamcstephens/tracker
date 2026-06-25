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

  # Conservative default; historical backfills pass an earlier `from:` to reach
  # back to 2020-03-27, where packages.json.br first appears.
  @default_release_cutoff ~U[2025-01-01T00:00:00Z]

  @doc "The configured default release cutoff (overridable via app env)."
  def default_cutoff,
    do: Application.get_env(:tracker, :release_cutoff_date, @default_release_cutoff)

  defmodule Release do
    use TypedStruct

    typedstruct do
      field :base_url, String.t(), enforce: true
      field :released_at, DateTime.t(), enforce: true
      field :revision, String.t()
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
          |> merge_revisions([])

        GenServer.call(server, {:put_releases, channel, releases})
        releases

      releases ->
        releases
    end
  end

  def find_previous_release(server \\ __MODULE__, channel, revision) do
    GenServer.call(server, {:find_previous_release, channel, revision})
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

  @doc """
  Synchronously refreshes a single channel's release listing.

  Options:
    - `from` - oldest `released_at` to include; overrides the default cutoff so
      historical backfills can reach earlier than the conservative default.
    - `until` - newest `released_at` to include; bounds a backfill to a window so
      the earliest history can be ingested without resolving every later release.
    - `releases_fetcher` - 1-arity function from channel name to a list of
      `%Release{}`. Defaults to fetching from S3. Useful in tests.
  """
  def refresh_channel(server \\ __MODULE__, channel, opts \\ []) do
    GenServer.call(server, {:refresh_channel, channel, opts}, :timer.minutes(2))
  end

  def put_releases(server \\ __MODULE__, channel, releases) do
    GenServer.call(server, {:put_releases, channel, releases})
  end

  @doc """
  Returns the most recently released revision for `channel`, or `nil` if
  the cache holds no releases for it.
  """
  def newest_revision(server \\ __MODULE__, channel) do
    GenServer.call(server, {:newest_revision, channel})
  end

  @doc """
  Returns the stored conditional-GET pointer for `channel`, or `nil`.

  The pointer is a map of `%{etag, last_modified, revision}` populated by
  the lightweight channel poll.
  """
  def get_pointer(server \\ __MODULE__, channel) do
    GenServer.call(server, {:get_pointer, channel})
  end

  def put_pointer(server \\ __MODULE__, channel, pointer) do
    GenServer.call(server, {:put_pointer, channel, pointer})
  end

  # S3 listing (extracted from ChannelWorker)

  @doc """
  Returns the full cached state: a map of channel name to release list.
  """
  def list_releases(server \\ __MODULE__) do
    GenServer.call(server, :list_releases)
  end

  @doc false
  def parse_releases(contents, from \\ nil, until \\ nil) do
    from = from || default_cutoff()

    contents
    |> List.wrap()
    |> Enum.map(fn %{"Key" => key, "LastModified" => last_modified} ->
      {:ok, released_at, _offset} = DateTime.from_iso8601(last_modified)

      %Release{
        base_url: "#{@releases_base_url}/#{key}",
        released_at: released_at
      }
    end)
    |> Enum.reject(fn release ->
      DateTime.before?(release.released_at, from) or
        (until != nil and DateTime.after?(release.released_at, until))
    end)
    |> Enum.sort_by(& &1.released_at, {:desc, DateTime})
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
      {:ok, %{releases: %{}, pointers: %{}, refreshing: false}, {:continue, :load}}
    else
      {:ok, %{releases: %{}, pointers: %{}, refreshing: false}}
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
    Logger.error(msg: "ReleaseCache refresh task failed", reason: inspect(reason))
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
      case Enum.find_index(releases, &(&1.revision == revision)) do
        nil -> nil
        index -> Enum.at(releases, index + 1)
      end

    {:reply, result, state}
  end

  def handle_call({:find_by_revision, channel, revision}, _from, state) do
    release =
      state.releases
      |> Map.get(channel, [])
      |> Enum.find(&(&1.revision == revision))

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

  def handle_call({:newest_revision, channel}, _from, state) do
    revision =
      case Map.get(state.releases, channel, []) do
        [%Release{revision: rev} | _] -> rev
        _ -> nil
      end

    {:reply, revision, state}
  end

  def handle_call({:get_pointer, channel}, _from, state) do
    {:reply, Map.get(state.pointers, channel), state}
  end

  def handle_call({:put_pointer, channel, pointer}, _from, state) do
    {:reply, :ok, %{state | pointers: Map.put(state.pointers, channel, pointer)}}
  end

  def handle_call({:refresh_channel, channel, opts}, _from, state) do
    from = Keyword.get(opts, :from)
    until = Keyword.get(opts, :until)
    fetcher = Keyword.get(opts, :releases_fetcher, fn ch -> fetch_and_parse(ch, from, until) end)
    existing = Map.get(state.releases, channel, [])
    releases = channel |> fetcher.() |> merge_revisions(existing)
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
      existing = Map.get(current_releases, channel, [])
      releases = channel |> fetch_and_parse() |> merge_revisions(existing)
      {channel, releases}
    end)
  end

  defp fetch_and_parse(channel, from \\ nil, until \\ nil) do
    channel |> fetch_releases() |> parse_releases(from, until)
  end

  defp merge_revisions(fresh_releases, existing_releases) do
    existing_by_url =
      Map.new(existing_releases, fn r -> {r.base_url, r.revision} end)

    req = Tracker.Nixpkgs.S3Cache.new()

    Enum.map(fresh_releases, fn %Release{} = release ->
      revision =
        cond do
          release.revision != nil -> release.revision
          rev = Map.get(existing_by_url, release.base_url) -> rev
          true -> fetch_revision(req, release.base_url)
        end

      %Release{release | revision: revision}
    end)
  end

  defp fetch_revision(req, base_url) do
    case Req.get(req, url: base_url <> "/git-revision") do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        String.trim(body)

      _ ->
        nil
    end
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

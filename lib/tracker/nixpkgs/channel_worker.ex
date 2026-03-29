defmodule Tracker.Nixpkgs.ChannelWorker do
  use Oban.Worker, queue: :channels, max_attempts: 10

  import Ecto.Query, only: [from: 2]
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"channel" => channel, "base_url" => base_url} = args}) do
    revision = Req.get!(req(), url: base_url <> "/git-revision").body

    case Tracker.Nixpkgs.ChannelRevision.find(channel, revision) do
      {:ok, %Tracker.Nixpkgs.ChannelRevision{result: result}}
      when result in [:success, :partial_success] ->
        :ok

      _ ->
        result =
          fetch_channel(channel, revision, base_url)
          |> maybe_put("released_at", args["released_at"])
          |> write_to_database()

        case result do
          :success -> :ok
          :partial_success -> :ok
          :error -> {:error, :load_failed}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def perform(%Oban.Job{args: %{"channel" => channel}}) do
    result = load_channel(channel)

    %{"channel" => channel} |> new(schedule_in: 4 * 60 * 60) |> Oban.insert!()

    case result do
      :ok -> :ok
      :success -> :ok
      :partial_success -> :ok
      :error -> {:error, :load_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  def start_all_channels() do
    Application.get_env(:tracker, :channels, [])
    |> Enum.filter(&(not channel_job_running?(&1)))
    |> Enum.each(fn channel ->
      %{"channel" => channel} |> Tracker.Nixpkgs.ChannelWorker.new() |> Oban.insert()
    end)
  end

  def load_channel(channel \\ "nixos-unstable") do
    {revision, base_url} = get_channel_revision(channel)

    case Tracker.Nixpkgs.ChannelRevision.find(channel, revision) do
      {:ok, %Tracker.Nixpkgs.ChannelRevision{result: :success}} ->
        :ok

      {:ok, %Tracker.Nixpkgs.ChannelRevision{result: :partial_success}} ->
        :ok

      _ ->
        fetch_channel(channel, revision, base_url)
        |> maybe_put("released_at", fetch_released_at(base_url))
        |> write_to_database()
    end
  end

  def channel_job_running?(channel) do
    query =
      from j in Oban.Job,
        where: j.state != "cancelled",
        where: j.state != "discarded",
        where: j.state != "completed",
        where: j.args["channel"] == ^channel

    Tracker.Repo.exists?(query)
  end

  def get_channel_revision(channel) do
    # get the redirected URL so we are consistent across queries
    # cache: false because we always want the latest redirect
    [base_url] =
      Req.get!(req(), url: "https://channels.nixos.org/#{channel}", redirect: false, cache: false).headers[
        "location"
      ]

    revision = Req.get!(req(), url: base_url <> "/git-revision").body

    {revision, base_url}
  end

  def fetch_channel(channel, revision, base_url) do
    Req.get!(req(), url: base_url <> "/packages.json.br", raw: true).body
    |> ExBrotli.decompress!()
    |> :json.decode()
    |> Map.put("revision", revision)
    |> Map.put("channel", channel)
  end

  @doc """
  Backfills historical channel data from releases.nixos.org.

  Lists all releases for the given channel from S3, filters out already-loaded
  revisions, and schedules Oban jobs for the rest (newest first).

  ## Options

    * `:limit` - maximum number of jobs to schedule (useful for testing)

  ## Examples

      ChannelWorker.backfill_channel("nixos-25.11-small", limit: 5)
  """
  def backfill_channel(channel, opts \\ []) do
    limit = Keyword.get(opts, :limit)

    releases =
      list_releases(channel)
      |> parse_releases()
      |> filter_existing_releases(channel)

    releases = if limit, do: Enum.take(releases, limit), else: releases

    Enum.each(releases, fn release ->
      %{
        "channel" => channel,
        "base_url" => release.base_url,
        "released_at" => release.released_at
      }
      |> new()
      |> Oban.insert!()
    end)

    {:ok, length(releases)}
  end

  defp list_releases(channel) do
    req_s3 = req() |> ReqS3.attach()
    list_releases(req_s3, channel, nil, [])
  end

  defp list_releases(req_s3, channel, marker, acc) do
    params =
      [delimiter: "/", prefix: "#{channel_to_s3_prefix(channel)}"]
      |> then(fn p -> if marker, do: Keyword.put(p, :marker, marker), else: p end)

    resp = Req.get!(req_s3, url: "s3://nix-releases", params: params)
    body = resp.body["ListBucketResult"]
    contents = body["Contents"] |> List.wrap()

    all_contents = acc ++ contents

    if body["IsTruncated"] == "true" do
      list_releases(req_s3, channel, body["NextMarker"], all_contents)
    else
      all_contents
    end
  end

  # Channel names like "nixos-25.11-small" map to S3 prefix "nixos/25.11-small/"
  defp channel_to_s3_prefix("nixos-" <> rest), do: "nixos/#{rest}/"
  defp channel_to_s3_prefix("nixpkgs-" <> rest), do: "nixpkgs/#{rest}/"
  defp channel_to_s3_prefix(channel), do: "#{channel}/"

  @releases_base_url "https://releases.nixos.org"

  @doc """
  Fetches the `LastModified` timestamp from S3 for a given release base URL.

  Does a targeted S3 listing with `max_keys: 1` to get the timestamp without
  downloading the full channel listing.
  """
  def fetch_released_at(base_url) do
    key = String.replace_prefix(base_url, @releases_base_url <> "/", "")
    req_s3 = req() |> ReqS3.attach()

    resp = Req.get!(req_s3, url: "s3://nix-releases", params: [prefix: key, max_keys: 1])

    resp.body["ListBucketResult"]["Contents"]
    |> List.wrap()
    |> List.first()
    |> case do
      %{"LastModified" => last_modified} -> last_modified
      _ -> nil
    end
  end

  @doc """
  Parses S3 Contents entries into release maps, sorted by `LastModified` descending (newest first).
  """
  def parse_releases(contents) do
    contents
    |> List.wrap()
    |> Enum.map(fn %{"Key" => key, "LastModified" => last_modified} ->
      short_hash = key |> String.split(".") |> List.last()

      %{
        short_hash: short_hash,
        base_url: "#{@releases_base_url}/#{key}",
        released_at: last_modified
      }
    end)
    |> Enum.sort_by(& &1.released_at, :desc)
  end

  @doc """
  Filters out releases that already exist in the database for the given channel.

  Matches short hashes from release directory names against existing full revision hashes.
  """
  def filter_existing_releases(releases, channel) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Tracker.Repo,
        "SELECT revision FROM channel_revisions WHERE channel = $1",
        [channel]
      )

    existing_hashes = MapSet.new(rows, fn [revision] -> revision end)

    Enum.reject(releases, fn release ->
      Enum.any?(existing_hashes, &String.starts_with?(&1, release.short_hash))
    end)
  end

  def write_to_database(
        %{
          "packages" => packages,
          "version" => version,
          "revision" => revision,
          "channel" => channel
        } = data
      )
      when version in [2, "2"] do
    packages =
      case Application.get_env(:tracker, :loader_limit) do
        nil -> packages
        limit -> Enum.take(packages, limit)
      end

    create_attrs =
      %{revision: revision, channel: channel}
      |> maybe_put(:released_at, data["released_at"])

    channel_revision =
      Tracker.Nixpkgs.ChannelRevision
      |> Ash.Changeset.for_create(:create, create_attrs)
      |> Ash.create!()

    # Slim down to only what we need: %{attribute => version}
    # Filter out packages with empty versions (wrappers, meta-packages, etc.)
    packages =
      packages
      |> Map.new(fn {attr, info} -> {attr, info["version"]} end)
      |> Map.reject(fn {_attr, version} -> version == "" end)

    bulk_status = load_packages(packages, channel_revision)

    if bulk_status != :success do
      Logger.error("Failed to load channel #{channel} at #{revision}")
    end

    channel_revision
    |> Ash.Changeset.for_update(:record_result, %{result: bulk_status})
    |> Ash.update!()

    bulk_status
  end

  def write_to_database(%{"version" => version}) do
    Logger.error("Unsupported packages.json version: #{inspect(version)}")
    {:error, :unsupported_version}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp req do
    if Application.get_env(:tracker, :http_cache, false) do
      Req.new(
        cache: true,
        cache_dir: Application.get_env(:tracker, :cache_dir, "_build/releases_cache")
      )
    else
      Req.new()
    end
  end

  @chunk_size 10_000

  # packages is %{attribute => version} (already slimmed)
  defp load_packages(packages, channel_revision) do
    # Step 1: Bulk upsert packages in chunks (no relationship management)
    pkg_status =
      packages
      |> Stream.map(fn {attribute, _version} -> %{attribute: attribute} end)
      |> Stream.chunk_every(@chunk_size)
      |> Enum.reduce(:success, fn chunk, acc ->
        %{status: status} =
          Ash.bulk_create(chunk, Tracker.Nixpkgs.Package, :bulk_upsert,
            batch_size: 5000,
            return_errors?: true
          )

        worst_status(acc, status)
      end)

    if pkg_status == :error do
      :error
    else
      # Step 2: Build attribute -> id lookup map via raw SQL (memory efficient)
      %{rows: rows} =
        Ecto.Adapters.SQL.query!(Tracker.Repo, "SELECT attribute, id FROM packages")

      id_map = Map.new(rows, fn [attribute, id] -> {attribute, id} end)

      # Step 3: Bulk create package revisions in chunks
      rev_status =
        packages
        |> Stream.map(fn {attribute, version} ->
          %{
            package_id: Map.fetch!(id_map, attribute),
            channel_revision_id: channel_revision.id,
            version: version
          }
        end)
        |> Stream.chunk_every(@chunk_size)
        |> Enum.reduce(:success, fn chunk, acc ->
          %{status: status} =
            Ash.bulk_create(chunk, Tracker.Nixpkgs.PackageRevision, :load,
              batch_size: 5000,
              return_errors?: true
            )

          worst_status(acc, status)
        end)

      worst_status(pkg_status, rev_status)
    end
  end

  defp worst_status(:error, _), do: :error
  defp worst_status(_, :error), do: :error
  defp worst_status(:partial_success, _), do: :partial_success
  defp worst_status(_, :partial_success), do: :partial_success
  defp worst_status(:success, :success), do: :success
end

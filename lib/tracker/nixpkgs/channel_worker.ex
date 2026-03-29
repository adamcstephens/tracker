defmodule Tracker.Nixpkgs.ChannelWorker do
  use Oban.Worker, queue: :channels, max_attempts: 10

  import Ecto.Query, only: [from: 2]
  require Logger

  @metadata_channel "nixos-unstable-small"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"channel" => channel, "base_url" => base_url} = args}) do
    force? = args["force"] == true
    revision = Req.get!(req(), url: base_url <> "/git-revision").body

    case Tracker.Nixpkgs.ChannelRevision.find(channel, revision) do
      {:ok, %Tracker.Nixpkgs.ChannelRevision{result: result}}
      when result in [:success, :partial_success] and not force? ->
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

  def perform(%Oban.Job{args: %{"channel" => channel} = args}) do
    force? = args["force"] == true
    result = load_channel(channel, force: force?)

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

  def load_channel(channel \\ "nixos-unstable", opts \\ []) do
    force? = Keyword.get(opts, :force, false)
    {revision, base_url} = get_channel_revision(channel)

    case Tracker.Nixpkgs.ChannelRevision.find(channel, revision) do
      {:ok, %Tracker.Nixpkgs.ChannelRevision{result: result}}
      when result in [:success, :partial_success] and not force? ->
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

    # Slim down to only what we need, filtering out empty versions
    include_metadata? = channel == @metadata_channel

    {packages, maintainer_data, team_data, package_joins} =
      packages
      |> Map.reject(fn {_attr, info} -> info["version"] == "" end)
      |> extract_packages(include_metadata?)

    bulk_status = load_packages(packages, channel_revision)

    if include_metadata? and bulk_status != :error do
      %{rows: rows} =
        Ecto.Adapters.SQL.query!(Tracker.Repo, "SELECT attribute, id FROM packages")

      id_map = Map.new(rows, fn [attribute, id] -> {attribute, id} end)
      load_maintainers_and_teams(id_map, maintainer_data, team_data, package_joins)
    end

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

  # packages is %{attribute => %{version, description?, homepage?}} (already slimmed)
  defp load_packages(packages, channel_revision) do
    # Step 1: Bulk upsert packages in chunks (includes metadata when present)
    pkg_status =
      packages
      |> Stream.map(fn {attribute, entry} ->
        %{attribute: attribute}
        |> maybe_put(:description, entry[:description])
        |> maybe_put(:homepage, entry[:homepage])
        |> maybe_put(:position, entry[:position])
        |> maybe_put(:licenses, entry[:licenses])
      end)
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
        |> Stream.map(fn {attribute, entry} ->
          %{
            package_id: Map.fetch!(id_map, attribute),
            channel_revision_id: channel_revision.id,
            version: entry.version
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

  defp extract_packages(packages, false) do
    pkgs = Map.new(packages, fn {attr, info} -> {attr, %{version: info["version"]}} end)
    {pkgs, %{}, %{}, %{}}
  end

  defp extract_packages(packages, true) do
    Enum.reduce(packages, {%{}, %{}, %{}, %{}}, fn {attr, info},
                                                   {pkgs, maint_acc, team_acc, joins} ->
      meta = info["meta"] || %{}

      entry =
        %{version: info["version"]}
        |> maybe_put(:description, meta["description"])
        |> maybe_put(:homepage, meta["homepage"])
        |> maybe_put(:position, meta["position"])
        |> maybe_put(:licenses, extract_licenses(meta["license"], attr))

      # Collect direct (non-team) maintainers
      non_team = meta["nonTeamMaintainers"] || []

      maint_acc =
        Enum.reduce(non_team, maint_acc, fn m, acc ->
          Map.put_new(acc, m["githubId"], extract_maintainer(m))
        end)

      # Collect teams and their members
      teams = meta["teams"] || []

      team_acc =
        Enum.reduce(teams, team_acc, fn t, acc ->
          Map.put_new(acc, t["shortName"], %{
            short_name: t["shortName"],
            scope: t["scope"],
            github: t["github"],
            github_id: t["githubId"],
            member_github_ids: Enum.map(t["members"] || [], & &1["githubId"])
          })
        end)

      # Team members also need to exist in the maintainers table
      maint_acc =
        teams
        |> Enum.flat_map(fn t -> t["members"] || [] end)
        |> Enum.reduce(maint_acc, fn m, acc ->
          Map.put_new(acc, m["githubId"], extract_maintainer(m))
        end)

      # Track per-package join info
      maintainer_ids = Enum.map(non_team, & &1["githubId"])
      team_names = Enum.map(teams, & &1["shortName"])

      joins =
        if maintainer_ids != [] or team_names != [] do
          Map.put(joins, attr, %{
            maintainer_github_ids: maintainer_ids,
            team_short_names: team_names
          })
        else
          joins
        end

      {Map.put(pkgs, attr, entry), maint_acc, team_acc, joins}
    end)
  end

  defp extract_maintainer(m) do
    %{github_id: m["githubId"], name: m["name"]}
    |> maybe_put(:email, m["email"])
    |> maybe_put(:github, m["github"])
    |> maybe_put(:matrix, m["matrix"])
  end

  defp extract_licenses(nil, _attr), do: nil
  defp extract_licenses(license, _attr) when is_binary(license), do: [license]
  defp extract_licenses(license, attr) when is_map(license), do: extract_licenses([license], attr)

  defp extract_licenses(licenses, attr) when is_list(licenses) do
    Enum.map(licenses, fn
      %{"spdxId" => id} ->
        id

      %{"shortName" => name} ->
        name

      %{"fullName" => name} ->
        name

      other when is_binary(other) ->
        other

      other ->
        Logger.error(
          msg: "Unrecognized license format",
          package: attr,
          license: inspect(other)
        )

        "unknown"
    end)
  end

  defp load_maintainers_and_teams(id_map, maintainer_data, team_data, package_joins) do
    # Step 1: Bulk upsert maintainers
    maintainer_data
    |> Map.values()
    |> Stream.chunk_every(@chunk_size)
    |> Enum.each(fn chunk ->
      Ash.bulk_create(chunk, Tracker.Nixpkgs.Maintainer, :bulk_upsert,
        batch_size: 5000,
        return_errors?: true
      )
    end)

    # Step 2: Bulk upsert teams
    team_attrs = Enum.map(Map.values(team_data), &Map.delete(&1, :member_github_ids))

    if team_attrs != [] do
      Ash.bulk_create(team_attrs, Tracker.Nixpkgs.Team, :bulk_upsert,
        batch_size: 5000,
        return_errors?: true
      )
    end

    # Step 3: Build lookup maps
    %{rows: maint_rows} =
      Ecto.Adapters.SQL.query!(Tracker.Repo, "SELECT github_id, id FROM maintainers")

    maintainer_id_map = Map.new(maint_rows, fn [github_id, id] -> {github_id, id} end)

    %{rows: team_rows} =
      Ecto.Adapters.SQL.query!(Tracker.Repo, "SELECT short_name, id FROM teams")

    team_id_map = Map.new(team_rows, fn [short_name, id] -> {short_name, id} end)

    # Step 4: Bulk upsert team members
    team_data
    |> Enum.flat_map(fn {short_name, team} ->
      team_id = Map.fetch!(team_id_map, short_name)

      Enum.map(team.member_github_ids, fn github_id ->
        %{team_id: team_id, maintainer_id: Map.fetch!(maintainer_id_map, github_id)}
      end)
    end)
    |> Stream.chunk_every(@chunk_size)
    |> Enum.each(fn chunk ->
      Ash.bulk_create(chunk, Tracker.Nixpkgs.TeamMember, :load,
        batch_size: 5000,
        return_errors?: true
      )
    end)

    # Step 5: Upsert package_maintainers (dedup to avoid PG cardinality violation)
    package_joins
    |> Enum.flat_map(fn {attr, joins} ->
      package_id = Map.fetch!(id_map, attr)

      joins.maintainer_github_ids
      |> Enum.uniq()
      |> Enum.map(fn github_id ->
        %{package_id: package_id, maintainer_id: Map.fetch!(maintainer_id_map, github_id)}
      end)
    end)
    |> Stream.chunk_every(@chunk_size)
    |> Enum.each(fn chunk ->
      Ash.bulk_create(chunk, Tracker.Nixpkgs.PackageMaintainer, :load,
        batch_size: 5000,
        return_errors?: true
      )
    end)

    # Step 6: Upsert package_teams
    package_joins
    |> Enum.flat_map(fn {attr, joins} ->
      package_id = Map.fetch!(id_map, attr)

      Enum.map(joins.team_short_names, fn short_name ->
        %{package_id: package_id, team_id: Map.fetch!(team_id_map, short_name)}
      end)
    end)
    |> Stream.chunk_every(@chunk_size)
    |> Enum.each(fn chunk ->
      Ash.bulk_create(chunk, Tracker.Nixpkgs.PackageTeam, :load,
        batch_size: 5000,
        return_errors?: true
      )
    end)

    :ok
  end

  defp worst_status(:error, _), do: :error
  defp worst_status(_, :error), do: :error
  defp worst_status(:partial_success, _), do: :partial_success
  defp worst_status(_, :partial_success), do: :partial_success
  defp worst_status(:success, :success), do: :success
end

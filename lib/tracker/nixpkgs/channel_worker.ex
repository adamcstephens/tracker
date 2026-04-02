defmodule Tracker.Nixpkgs.ChannelWorker do
  use Oban.Worker, queue: :channels, max_attempts: 10

  require Logger

  @metadata_channel "nixos-unstable-small"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"channel" => channel, "base_url" => base_url} = args}) do
    force? = args["force"] == true
    revision = Req.get!(Tracker.Nixpkgs.S3Cache.new(), url: base_url <> "/git-revision").body

    process_channel(channel, base_url, revision, args["released_at"], force: force?)
    schedule_next(args)
    :ok
  end

  def perform(%Oban.Job{args: %{"channel" => channel} = args}) do
    force? = args["force"] == true
    {revision, base_url} = get_channel_revision(channel)
    released_at = resolve_released_at(channel, base_url)

    process_channel(channel, base_url, revision, released_at, force: force?)
    :ok
  end

  def load_channel(channel \\ "nixos-unstable", opts \\ []) do
    force? = Keyword.get(opts, :force, false)
    {revision, base_url} = get_channel_revision(channel)
    released_at = resolve_released_at(channel, base_url)

    process_channel(channel, base_url, revision, released_at, force: force?)
  end

  def get_channel_revision(channel) do
    # get the redirected URL so we are consistent across queries
    # cache: false because we always want the latest redirect
    [base_url] =
      Req.get!(Tracker.Nixpkgs.S3Cache.new(),
        url: "https://channels.nixos.org/#{channel}",
        redirect: false,
        cache: false
      ).headers[
        "location"
      ]

    revision = Req.get!(Tracker.Nixpkgs.S3Cache.new(), url: base_url <> "/git-revision").body

    {revision, base_url}
  end

  def fetch_channel(channel, revision, base_url) do
    Req.get!(Tracker.Nixpkgs.S3Cache.new(), url: base_url <> "/packages.json.br", raw: true).body
    |> ExBrotli.decompress!()
    |> :json.decode()
    |> Map.put("revision", revision)
    |> Map.put("channel", channel)
    |> Map.put("base_url", base_url)
  end

  @doc """
  Backfills historical channel data from releases.nixos.org.

  Lists all releases for the given channel from S3, filters out already-loaded
  revisions, and schedules chained Oban jobs starting from the oldest release.
  Each job schedules the next upon completion, ensuring sequential chronological
  ingestion so package events are generated correctly.

  Already-loaded revisions are filtered out before scheduling, but if a revision
  is encountered during execution that was loaded between scheduling and execution,
  it will be skipped quickly and the chain continues.

  ## Options

    * `:limit` - maximum number of releases to process, taken from the oldest

  ## Examples

      ChannelWorker.backfill_channel("nixos-25.11-small", limit: 5)
  """
  def backfill_channel(channel, opts \\ []) do
    limit = Keyword.get(opts, :limit)

    releases =
      Tracker.Nixpkgs.ReleaseCache.get_releases(channel)
      |> Enum.reverse()
      |> filter_existing_releases(channel)

    releases = if limit, do: Enum.take(releases, limit), else: releases

    case releases do
      [] ->
        {:ok, 0}

      [first | rest] ->
        %{
          "channel" => channel,
          "base_url" => first.base_url,
          "released_at" => first.released_at,
          "remaining" => length(rest)
        }
        |> new()
        |> Oban.insert!()

        {:ok, length(releases)}
    end
  end

  @doc """
  Schedules the next backfill job by looking up the next release in the cache.

  Called after a backfill job completes successfully. No-op if there are no
  remaining releases or if the key is absent (non-backfill jobs).
  """
  def schedule_next(%{"remaining" => remaining, "base_url" => base_url, "channel" => channel})
      when remaining > 0 do
    releases = Tracker.Nixpkgs.ReleaseCache.get_releases(channel) |> Enum.reverse()

    case find_next_release(releases, base_url) do
      nil ->
        :ok

      next ->
        %{
          "channel" => channel,
          "base_url" => next.base_url,
          "released_at" => next.released_at,
          "remaining" => remaining - 1
        }
        |> new()
        |> Oban.insert!()
    end
  end

  def schedule_next(_args), do: :ok

  defp has_options?(channel), do: String.starts_with?(channel, "nixos-")

  defp process_channel(channel, base_url, revision, released_at, opts) do
    force? = Keyword.get(opts, :force, false)

    case Tracker.Nixpkgs.ChannelRevision.find(channel, revision) do
      {:ok, %Tracker.Nixpkgs.ChannelRevision{result: result}}
      when result in [:success, :partial_success] and not force? ->
        :already_loaded

      _ ->
        fetch_channel(channel, revision, base_url)
        |> maybe_put("released_at", released_at)
        |> write_to_database()
    end
  end

  defp resolve_released_at(channel, base_url) do
    case Tracker.Nixpkgs.ReleaseCache.find_by_base_url(channel, base_url) do
      %{released_at: released_at} -> released_at
      nil -> DateTime.utc_now()
    end
  end

  defp find_next_release(releases, base_url) do
    case Enum.find_index(releases, &(&1.base_url == base_url)) do
      nil -> nil
      index -> Enum.at(releases, index + 1)
    end
  end

  @doc """
  Filters out releases that already exist in the database for the given channel.

  Uses base_url to match releases against existing channel revisions.
  """
  def filter_existing_releases(releases, channel) do
    existing_hashes =
      Tracker.Nixpkgs.ChannelRevision.by_channel!(channel)
      |> MapSet.new(& &1.revision)

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

    alias Tracker.Nixpkgs.ReleaseCache

    previous_release = ReleaseCache.find_previous_release(channel, revision)

    previous_revision =
      case previous_release do
        nil ->
          nil

        %ReleaseCache.Release{short_hash: prev_hash} ->
          case Tracker.Nixpkgs.ChannelRevision.find_by_channel_hash(channel, prev_hash) do
            {:ok, rev} -> rev
            _ -> nil
          end
      end

    create_attrs =
      %{
        revision: revision,
        channel: channel,
        released_at: data["released_at"] || DateTime.utc_now()
      }
      |> maybe_put(:previous_channel_revision_id, previous_revision && previous_revision.id)

    channel_revision = Tracker.Nixpkgs.ChannelRevision.create!(create_attrs)

    # Slim down to only what we need, filtering out empty versions
    include_metadata? = channel == @metadata_channel

    {packages, maintainer_data, team_data, package_joins} =
      packages
      |> Map.reject(fn {_attr, info} -> info["version"] in ["", nil] end)
      |> extract_packages(include_metadata?)

    id_map = load_packages(packages, channel_revision)

    parallel_tasks =
      [
        if(include_metadata?,
          do:
            Task.async(fn ->
              load_maintainers_and_teams(id_map, maintainer_data, team_data, package_joins)
            end)
        ),
        if(previous_revision,
          do:
            Task.async(fn ->
              detect_package_events(channel_revision, previous_revision)
            end)
        )
      ]
      |> Enum.reject(&is_nil/1)

    Task.await_many(parallel_tasks, :infinity)

    Tracker.Nixpkgs.ChannelRevision.record_result!(channel_revision, %{result: :success})

    if base_url = has_options?(channel) && data["base_url"] do
      Tracker.Nixpkgs.OptionsWorker.new(%{
        "channel" => channel,
        "base_url" => base_url,
        "revision" => revision
      })
      |> Oban.insert!()
    end

    Phoenix.PubSub.broadcast(
      Tracker.PubSub,
      "channel_revisions:#{channel}",
      {:channel_revision_completed, %{channel: channel, revision: revision}}
    )

    :success
  end

  def write_to_database(%{"version" => version}) do
    Logger.error("Unsupported packages.json version: #{inspect(version)}")
    {:error, :unsupported_version}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_homepage(nil), do: nil
  defp normalize_homepage(urls) when is_list(urls), do: urls
  defp normalize_homepage(url) when is_binary(url), do: [url]

  # packages is %{attribute => %{version, description?, homepage?}} (already slimmed)
  defp load_packages(packages, channel_revision) do
    alias Tracker.Nixpkgs.PackageSetMapping

    # Step 0: Parse attributes and upsert package families
    parsed_attrs =
      Map.new(packages, fn {attribute, _} -> {attribute, PackageSetMapping.parse(attribute)} end)

    families =
      parsed_attrs
      |> Map.values()
      |> Enum.filter(& &1.family_name)
      |> Enum.uniq_by(&{&1.family_name, &1.ecosystem})
      |> Enum.map(&%{name: &1.family_name, ecosystem: &1.ecosystem || ""})

    family_id_map = Tracker.Nixpkgs.PackageFamily.bulk_upsert_all(families)

    # Step 1: Bulk upsert packages
    id_map =
      packages
      |> Enum.map(fn {attribute, entry} ->
        parsed = Map.fetch!(parsed_attrs, attribute)

        family_id =
          if parsed.family_name,
            do: Map.get(family_id_map, {parsed.family_name, parsed.ecosystem || ""}),
            else: nil

        %{attribute: attribute}
        |> maybe_put(:description, entry[:description])
        |> maybe_put(:homepage, entry[:homepage])
        |> maybe_put(:position, entry[:position])
        |> maybe_put(:licenses, entry[:licenses])
        |> maybe_put(:package_family_id, family_id)
        |> maybe_put(:package_set, parsed.package_set)
        |> maybe_put(:set_version, parsed.set_version)
      end)
      |> Tracker.Nixpkgs.Package.bulk_upsert_all()

    # Step 2: Bulk create package revisions
    packages
    |> Enum.map(fn {attribute, entry} ->
      %{
        package_id: Map.fetch!(id_map, attribute),
        channel_revision_id: channel_revision.id,
        version: entry.version
      }
    end)
    |> Tracker.Nixpkgs.PackageRevision.bulk_insert_all()

    id_map
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
        |> maybe_put(:homepage, normalize_homepage(meta["homepage"]))
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
    # Step 1: Bulk upsert maintainers and teams in parallel
    maintainer_task =
      Task.async(fn ->
        maintainer_data |> Map.values() |> Tracker.Nixpkgs.Maintainer.bulk_upsert_all()
        maintainer_id_map()
      end)

    team_task =
      Task.async(fn ->
        team_data
        |> Map.values()
        |> Enum.map(&Map.delete(&1, :member_github_ids))
        |> Tracker.Nixpkgs.Team.bulk_upsert_all()

        team_id_map()
      end)

    maintainer_id_map = Task.await(maintainer_task)
    team_id_map = Task.await(team_task)

    # Step 2: Bulk upsert team members, package_maintainers, and package_teams in parallel
    team_member_task =
      Task.async(fn ->
        team_data
        |> Enum.flat_map(fn {short_name, team} ->
          team_id = Map.fetch!(team_id_map, short_name)

          Enum.map(team.member_github_ids, fn github_id ->
            %{team_id: team_id, maintainer_id: Map.fetch!(maintainer_id_map, github_id)}
          end)
        end)
        |> Tracker.Nixpkgs.TeamMember.bulk_create_all()
      end)

    pkg_maintainer_task =
      Task.async(fn ->
        package_joins
        |> Enum.flat_map(fn {attr, joins} ->
          package_id = Map.fetch!(id_map, attr)

          joins.maintainer_github_ids
          |> Enum.uniq()
          |> Enum.map(fn github_id ->
            %{package_id: package_id, maintainer_id: Map.fetch!(maintainer_id_map, github_id)}
          end)
        end)
        |> Tracker.Nixpkgs.PackageMaintainer.bulk_create_all()
      end)

    pkg_team_task =
      Task.async(fn ->
        package_joins
        |> Enum.flat_map(fn {attr, joins} ->
          package_id = Map.fetch!(id_map, attr)

          Enum.map(joins.team_short_names, fn short_name ->
            %{package_id: package_id, team_id: Map.fetch!(team_id_map, short_name)}
          end)
        end)
        |> Tracker.Nixpkgs.PackageTeam.bulk_create_all()
      end)

    Task.await_many([team_member_task, pkg_maintainer_task, pkg_team_task])

    :ok
  end

  defp detect_package_events(channel_revision, previous_revision) do
    {added, removed} =
      Tracker.Nixpkgs.PackageRevision.diff_package_ids(channel_revision.id, previous_revision.id)

    events =
      Enum.map(added, fn package_id ->
        %{type: :added, package_id: package_id, channel_revision_id: channel_revision.id}
      end) ++
        Enum.map(removed, fn package_id ->
          %{type: :removed, package_id: package_id, channel_revision_id: channel_revision.id}
        end)

    Tracker.Nixpkgs.PackageEvent.bulk_create_all(events)
  end

  defp maintainer_id_map do
    Tracker.Nixpkgs.Maintainer.id_map!()
    |> Map.new(&{&1.github_id, &1.id})
  end

  defp team_id_map do
    Tracker.Nixpkgs.Team.id_map!()
    |> Map.new(&{&1.short_name, &1.id})
  end
end

defmodule Tracker.Ingestion.Steps.LoadPackages do
  @moduledoc """
  Fetches packages.json.br, parses, and bulk upserts packages,
  families, variant groups, and revisions.

  For the metadata channel, also loads maintainers, teams, and
  their join tables in a single fetch+parse cycle.
  """

  @behaviour Tracker.Ingestion.Step

  require Logger

  alias Tracker.Ingestion.{Helpers, StepGraph}
  alias Tracker.Nixpkgs.Channel

  @impl true
  def timeout, do: :timer.minutes(30)

  @impl true
  def run(%Tracker.Ingestion.StepContext{pipeline: pipeline, channel_revision: channel_revision}) do
    data = Channel.fetch_packages(pipeline.channel, pipeline.revision, pipeline.base_url)

    packages = data["packages"]

    packages =
      case Application.get_env(:tracker, :loader_limit) do
        nil -> packages
        limit -> Enum.take(packages, limit)
      end

    include_metadata? = pipeline.channel == StepGraph.metadata_channel()

    {packages, maintainer_data, team_data, package_joins} =
      packages
      |> Map.reject(fn {_attr, info} -> info["version"] in ["", nil] end)
      |> extract_packages(include_metadata?)

    id_map = load_packages(packages, channel_revision)

    if include_metadata? do
      load_maintainers_and_teams(id_map, maintainer_data, team_data, package_joins)
    end

    :ok
  end

  # -- Package extraction --

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
        |> Helpers.maybe_put(:description, meta["description"])
        |> Helpers.maybe_put(:homepage, normalize_homepage(meta["homepage"]))
        |> Helpers.maybe_put(:position, meta["position"])
        |> Helpers.maybe_put(:licenses, extract_licenses(meta["license"], attr))

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
          Map.put_new(acc, String.downcase(t["shortName"]), %{
            short_name: String.downcase(t["shortName"]),
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
      team_names = Enum.map(teams, &String.downcase(&1["shortName"]))

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
    %{github_id: m["githubId"]}
    |> Helpers.maybe_put(:github, m["github"])
  end

  defp normalize_homepage(nil), do: nil
  defp normalize_homepage(urls) when is_list(urls), do: urls
  defp normalize_homepage(url) when is_binary(url), do: [url]

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

  # -- Package loading --

  defp load_packages(packages, channel_revision) do
    alias Tracker.Nixpkgs.PackageSetMapping

    parsed_attrs =
      Map.new(packages, fn {attribute, _} -> {attribute, PackageSetMapping.parse(attribute)} end)

    families =
      parsed_attrs
      |> Map.values()
      |> Enum.filter(& &1.family_name)
      |> Enum.uniq_by(&{&1.family_name, &1.ecosystem})
      |> Enum.map(&%{name: &1.family_name, ecosystem: &1.ecosystem || ""})

    family_id_map = Tracker.Nixpkgs.PackageFamily.bulk_upsert_all(families)

    variant_group_id_map =
      packages
      |> Enum.filter(fn {attribute, entry} ->
        parsed = Map.fetch!(parsed_attrs, attribute)
        is_nil(parsed.package_set) and entry[:position] not in [nil, ""]
      end)
      |> Enum.group_by(fn {_attr, entry} -> entry[:position] end)
      |> Enum.filter(fn {_pos, members} -> length(members) >= 2 end)
      |> Enum.map(fn {position, _} -> %{position: position} end)
      |> Tracker.Nixpkgs.PackageVariantGroup.bulk_upsert_all()

    id_map =
      packages
      |> Enum.map(fn {attribute, entry} ->
        parsed = Map.fetch!(parsed_attrs, attribute)

        family_id =
          if parsed.family_name,
            do: Map.get(family_id_map, {parsed.family_name, parsed.ecosystem || ""}),
            else: nil

        variant_group_id =
          if is_nil(parsed.package_set) and entry[:position],
            do: Map.get(variant_group_id_map, entry[:position]),
            else: nil

        %{attribute: attribute}
        |> Helpers.maybe_put(:description, entry[:description])
        |> Helpers.maybe_put(:homepage, entry[:homepage])
        |> Helpers.maybe_put(:position, entry[:position])
        |> Helpers.maybe_put(:licenses, entry[:licenses])
        |> Helpers.maybe_put(:package_family_id, family_id)
        |> Helpers.maybe_put(:package_variant_group_id, variant_group_id)
        |> Helpers.maybe_put(:package_set, parsed.package_set)
        |> Helpers.maybe_put(:set_version, parsed.set_version)
      end)
      |> Tracker.Nixpkgs.Package.bulk_upsert_all()

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

  # -- Maintainer/team loading --

  defp load_maintainers_and_teams(id_map, maintainer_data, team_data, package_joins) do
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

    maintainer_id_map = Task.await(maintainer_task, :timer.minutes(5))
    team_id_map = Task.await(team_task, :timer.minutes(5))

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

    Task.await_many([team_member_task, pkg_maintainer_task, pkg_team_task], :timer.minutes(5))

    :ok
  end

  defp maintainer_id_map do
    Tracker.Nixpkgs.Maintainer.id_map!()
    |> Map.new(&{&1.github_id, &1.id})
  end

  defp team_id_map do
    Tracker.Nixpkgs.Team.id_map!()
    |> Map.new(&{to_string(&1.short_name), &1.id})
  end
end

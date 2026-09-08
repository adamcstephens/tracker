defmodule Tracker.Ingestion.Steps.LoadPackages do
  @moduledoc """
  Fetches packages.json.br and streams packages via a Rust NIF,
  then bulk upserts packages, families, variant groups, and revisions.

  For the metadata channel, also loads maintainers, teams, and
  their join tables after all packages are processed.
  """

  @behaviour Tracker.Ingestion.Step

  alias Tracker.Ingestion.{Helpers, PackageStream, StepGraph}
  alias Tracker.Nixpkgs.ChannelFetcher

  require Logger

  @stream_timeout :timer.minutes(25)

  @meta_fields [
    :description,
    :long_description,
    :homepage,
    :position,
    :licenses,
    :pname,
    :outputs,
    :default_output,
    :main_program,
    :broken,
    :unfree,
    :insecure,
    :unsupported,
    :known_vulnerabilities,
    :platforms,
    :bad_platforms,
    :changelog,
    :download_page,
    :source_provenance
  ]

  @impl true
  def timeout, do: :timer.minutes(30)

  @impl true
  def run(%Tracker.Ingestion.StepContext{pipeline: pipeline, channel_revision: channel_revision}) do
    compressed = ChannelFetcher.fetch_packages_compressed(pipeline.base_url)
    channel = Tracker.Nixpkgs.Channel.by_id!(pipeline.channel_id)
    metadata_channel? = channel.name == StepGraph.metadata_channel()

    # stream_packages/2 is a synchronous DirtyCpu NIF that blocks its caller
    # until decompress + parse finish. Run it in a Task so this process stays
    # free to drain the {:packages, _} batches it sends concurrently; piling
    # them in the NIF caller's own mailbox would deadlock.
    parent = self()
    stream_task = Task.async(fn -> PackageStream.stream_packages(compressed, parent) end)

    {packages, stream_meta} = collect_all_packages()
    :ok = Task.await(stream_task, @stream_timeout)

    log_unknown_platform_patterns(stream_meta[:unknown_platform_patterns] || [])

    {extracted, maint_data, team_data, joins} = extract_packages(packages)

    id_map = load_packages(extracted, channel_revision)

    if metadata_channel? do
      Tracker.Nixpkgs.Channel.reconcile_metadata!(
        channel.id,
        %Tracker.Nixpkgs.MetadataSnapshot{
          package_ids: id_map,
          maintainers: maint_data,
          teams: team_data,
          joins: joins
        }
      )
    end

    :ok
  end

  defp log_unknown_platform_patterns([]), do: :ok

  defp log_unknown_platform_patterns(patterns) do
    Logger.warning(
      "LoadPackages: #{length(patterns)} unknown platform patterns in packages.json: " <>
        Enum.join(patterns, " ")
    )
  end

  # -- Collect all packages from NIF stream --

  defp collect_all_packages(acc \\ %{}) do
    receive do
      {:packages, entries} ->
        acc = Enum.reduce(entries, acc, fn {attr, fields}, a -> Map.put(a, attr, fields) end)
        collect_all_packages(acc)

      {:done, meta} ->
        {acc, meta}

      {:error, reason} ->
        raise "PackageStream NIF error: #{reason}"
    after
      @stream_timeout ->
        raise "PackageStream timed out waiting for messages"
    end
  end

  # -- Package extraction --

  defp extract_packages(packages) do
    Enum.reduce(packages, {%{}, %{}, %{}, %{}}, fn {attr, fields},
                                                   {pkgs, maint_acc, team_acc, joins} ->
      entry =
        Enum.reduce(@meta_fields, %{version: fields[:version]}, fn key, entry ->
          Helpers.maybe_put(entry, key, fields[key])
        end)

      # Collect direct (non-team) maintainers
      non_team = fields[:maintainers] || []

      maint_acc =
        Enum.reduce(non_team, maint_acc, fn m, acc ->
          Map.put_new(acc, m[:github_id], extract_maintainer(m))
        end)

      # Collect teams and their members
      teams = fields[:teams] || []

      team_acc =
        Enum.reduce(teams, team_acc, fn t, acc ->
          Map.put_new(acc, String.downcase(t[:short_name]), %{
            short_name: String.downcase(t[:short_name]),
            scope: t[:scope],
            github: t[:github],
            github_id: t[:github_id],
            member_github_ids: Enum.map(t[:members] || [], & &1[:github_id])
          })
        end)

      # Team members also need to exist in the maintainers table
      maint_acc =
        teams
        |> Enum.flat_map(fn t -> t[:members] || [] end)
        |> Enum.reduce(maint_acc, fn m, acc ->
          Map.put_new(acc, m[:github_id], extract_maintainer(m))
        end)

      # Track per-package join info
      maintainer_ids = Enum.map(non_team, & &1[:github_id])
      team_names = Enum.map(teams, &String.downcase(&1[:short_name]))

      joins =
        Map.put(joins, attr, %{
          maintainer_github_ids: maintainer_ids,
          team_short_names: team_names
        })

      {Map.put(pkgs, attr, entry), maint_acc, team_acc, joins}
    end)
  end

  defp extract_maintainer(m) do
    %{github_id: m[:github_id]}
    |> Helpers.maybe_put(:github, m[:github])
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
        |> Helpers.maybe_put(:package_family_id, family_id)
        |> Helpers.maybe_put(:package_variant_group_id, variant_group_id)
      end)
      |> Tracker.Nixpkgs.Package.bulk_upsert_all()

    # Version + metadata are temporal: fold this revision's full set into the
    # package spans. The set was just streamed in full, so it is complete —
    # absent packages are genuine removals.
    incoming =
      Enum.map(packages, fn {attribute, entry} ->
        parsed = Map.fetch!(parsed_attrs, attribute)

        @meta_fields
        |> Map.new(&{&1, entry[&1]})
        |> Map.merge(%{
          package_id: Map.fetch!(id_map, attribute),
          version: entry[:version],
          package_set: parsed.package_set,
          set_version: parsed.set_version
        })
      end)

    Tracker.Nixpkgs.SpanEngine.diff_and_apply(
      Tracker.Nixpkgs.PackageSpan.spec(),
      channel_revision.channel_id,
      channel_revision.released_at,
      incoming,
      complete?: true
    )

    id_map
  end
end

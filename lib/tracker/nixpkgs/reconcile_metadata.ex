defmodule Tracker.Nixpkgs.ReconcileMetadata do
  use Ash.Resource.Actions.Implementation

  alias Tracker.Ingestion.StepGraph
  alias Tracker.Nixpkgs.{Channel, Maintainer, PackageMaintainer, PackageTeam, Team, TeamMember}

  @batch_size 5_000
  @transaction_timeout :timer.minutes(5)

  @impl true
  def run(input, _opts, _context) do
    channel = Channel.by_id!(input.arguments.channel_id)

    if channel.name == StepGraph.metadata_channel() do
      Ash.DataLayer.transaction(
        [Maintainer, Team, PackageMaintainer, TeamMember, PackageTeam],
        fn ->
          apply_snapshot(input.arguments.snapshot)
          :applied
        end,
        @transaction_timeout
      )
    else
      {:ok, :skipped}
    end
  end

  defp apply_snapshot(snapshot) do
    snapshot.maintainers |> Map.values() |> Maintainer.bulk_upsert_all()
    maintainers = Map.new(Maintainer.id_map!(), &{&1.github_id, &1.id})

    existing_teams = Map.new(Team.read!(), &{to_string(&1.short_name), &1})

    changed_teams =
      for {name, team} <- snapshot.teams,
          attrs = Map.take(team, [:short_name, :scope, :github, :github_id]),
          team_changed?(existing_teams[name], attrs),
          do: attrs

    Team.bulk_upsert_all(changed_teams)
    teams = Map.new(Team.id_map!(), &{to_string(&1.short_name), &1.id})

    package_maintainers =
      for {attribute, joins} <- snapshot.joins,
          github_id <- joins.maintainer_github_ids do
        %{
          package_id: Map.fetch!(snapshot.package_ids, attribute),
          maintainer_id: Map.fetch!(maintainers, github_id)
        }
      end

    team_members =
      for {name, team} <- snapshot.teams,
          github_id <- team.member_github_ids do
        %{team_id: Map.fetch!(teams, name), maintainer_id: Map.fetch!(maintainers, github_id)}
      end

    package_teams =
      for {attribute, joins} <- snapshot.joins,
          name <- joins.team_short_names do
        %{
          package_id: Map.fetch!(snapshot.package_ids, attribute),
          team_id: Map.fetch!(teams, name)
        }
      end

    reconcile(PackageMaintainer, package_maintainers, [:package_id, :maintainer_id])
    reconcile(TeamMember, team_members, [:team_id, :maintainer_id])
    reconcile(PackageTeam, package_teams, [:package_id, :team_id])

    obsolete_teams =
      for {name, team} <- existing_teams, not Map.has_key?(snapshot.teams, name), do: team

    destroy_all(Team, obsolete_teams)
  end

  defp team_changed?(nil, _attrs), do: true

  defp team_changed?(team, attrs) do
    Enum.any?([:scope, :github, :github_id], &(Map.fetch!(team, &1) != Map.fetch!(attrs, &1)))
  end

  defp reconcile(resource, incoming, keys) do
    key = fn row -> Enum.map(keys, &Map.fetch!(row, &1)) end
    existing = Map.new(resource.relation_keys!(), &{key.(&1), &1})
    desired = Map.new(incoming, &{key.(&1), &1})
    added = for {pair, row} <- desired, not Map.has_key?(existing, pair), do: row
    removed = for {pair, row} <- existing, not Map.has_key?(desired, pair), do: row

    resource.bulk_create_all(added)
    destroy_all(resource, removed)
  end

  defp destroy_all(resource, records) do
    records
    |> Stream.chunk_every(@batch_size)
    |> Enum.each(fn chunk ->
      case Ash.bulk_destroy(chunk, :destroy, %{},
             resource: resource,
             strategy: [:atomic_batches],
             batch_size: @batch_size,
             return_errors?: true
           ) do
        %Ash.BulkResult{status: :success} ->
          :ok

        %Ash.BulkResult{errors: errors} ->
          raise "bulk #{inspect(resource)}.destroy failed: #{inspect(errors, limit: 5)}"
      end
    end)
  end
end

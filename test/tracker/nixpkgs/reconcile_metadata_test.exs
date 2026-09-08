defmodule Tracker.Nixpkgs.ReconcileMetadataTest do
  use Tracker.DataCase, async: false

  alias Tracker.Ingestion.StepGraph

  alias Tracker.Nixpkgs.{
    Channel,
    Maintainer,
    MetadataSnapshot,
    Package,
    PackageMaintainer,
    PackageTeam,
    Team,
    TeamMember
  }

  setup do
    channel =
      Channel.create!(%{
        name: StepGraph.metadata_channel(),
        display_name: "metadata",
        status: :active,
        is_stable: false
      })

    package =
      Package.bulk_upsert_all([%{attribute: "metadata-test"}]) |> Map.fetch!("metadata-test")

    %{channel: channel, package: package}
  end

  test "reapplying the current snapshot removes stale joins and preserves retained rows", ctx do
    snapshot = snapshot(ctx.package)
    assert Channel.reconcile_metadata!(ctx.channel.id, snapshot) == :applied

    stale = Maintainer.bulk_upsert!(%{github_id: 33, github: "stale"})
    PackageMaintainer.load!(%{package_id: ctx.package, maintainer_id: stale.id})

    retained =
      PackageMaintainer.read!(
        query: [filter: [maintainer_id: Maintainer.get_by_github!("alice").id]]
      )

    assert Channel.reconcile_metadata!(ctx.channel.id, snapshot) == :applied
    assert PackageMaintainer.read!() == retained
    assert Maintainer.get_by_github!("stale").id == stale.id
  end

  test "non-metadata channels cannot apply or clear global metadata", ctx do
    Channel.reconcile_metadata!(ctx.channel.id, snapshot(ctx.package))
    before = state(ctx.channel)

    other =
      Channel.create!(%{name: "other", display_name: "other", status: :active, is_stable: false})

    assert Channel.reconcile_metadata!(other.id, empty()) ==
             :skipped

    assert state(ctx.channel) == before
  end

  test "late package-team failure rolls back identities and earlier relation changes", ctx do
    Channel.reconcile_metadata!(ctx.channel.id, snapshot(ctx.package))
    before = state(ctx.channel)
    broken = snapshot(ctx.package)

    broken = %{
      broken
      | maintainers: %{
          11 => %{github_id: 11, github: "renamed"},
          22 => %{github_id: 22, github: "bob"}
        },
        package_ids: Map.put(broken.package_ids, "missing", -1),
        joins:
          Map.put(broken.joins, "missing", %{
            maintainer_github_ids: [],
            team_short_names: ["team"]
          })
    }

    assert {:error, _} = Channel.reconcile_metadata(ctx.channel.id, broken)
    assert state(ctx.channel) == before
  end

  test "deduplicates desired pairs and preserves reverse lookups", ctx do
    input = snapshot(ctx.package)

    input = %{
      input
      | teams: put_in(input.teams, ["team", :member_github_ids], [22, 22]),
        joins: %{
          "metadata-test" => %{
            maintainer_github_ids: [11, 11],
            team_short_names: ["team", "team"]
          }
        }
    }

    Channel.reconcile_metadata!(ctx.channel.id, input)
    assert length(PackageMaintainer.read!()) == 1
    assert length(TeamMember.read!()) == 1
    assert length(PackageTeam.read!()) == 1
    assert [%{id: id}] = Maintainer.get_by_github!("alice", load: [:packages]).packages
    assert id == ctx.package
    assert [%{github: "bob"}] = Team.get_by_short_name!("team", load: [:members]).members
    assert [%{id: ^id}] = Team.get_by_short_name!("team", load: [:packages]).packages
  end

  test "a later failure rolls back multiple completed create batches", ctx do
    Channel.reconcile_metadata!(ctx.channel.id, snapshot(ctx.package))
    before = state(ctx.channel)
    ids = Enum.to_list(100_000..113_107)
    input = snapshot(ctx.package)

    input = %{
      input
      | maintainers: Map.merge(input.maintainers, Map.new(ids, &{&1, %{github_id: &1}})),
        package_ids: Map.put(input.package_ids, "missing", -1),
        joins: %{
          "metadata-test" => %{maintainer_github_ids: ids, team_short_names: []},
          "missing" => %{maintainer_github_ids: [], team_short_names: ["team"]}
        }
    }

    assert {:error, _} = Channel.reconcile_metadata(ctx.channel.id, input)
    assert state(ctx.channel) == before
  end

  test "bulk validation failure cannot commit partially successful identity writes", ctx do
    Channel.reconcile_metadata!(ctx.channel.id, snapshot(ctx.package))
    before = state(ctx.channel)
    input = empty()

    input = %{
      input
      | maintainers: %{
          55 => %{github_id: 55, github: "valid"},
          nil => %{github_id: nil, github: "invalid"}
        }
    }

    assert {:error, _} = Channel.reconcile_metadata(ctx.channel.id, input)
    assert state(ctx.channel) == before
  end

  test "obsolete-team destroy failure rolls back the entire snapshot", ctx do
    Channel.reconcile_metadata!(ctx.channel.id, snapshot(ctx.package))
    before = state(ctx.channel)
    team = Team.get_by_short_name!("team")
    member = Maintainer.get_by_github!("bob")
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:ash, :nixpkgs, :bulk_destroy, :start],
        &__MODULE__.block_team_deletion/4,
        {handler, self(), team.id, member.id}
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:error, error} = Channel.reconcile_metadata(ctx.channel.id, empty())
    assert_received :team_deletion_blocked
    assert Exception.message(error) =~ "would leave records behind"
    assert state(ctx.channel) == before
  end

  def block_team_deletion(
        _event,
        _measurements,
        %{resource_short_name: :team},
        {handler, parent, team_id, maintainer_id}
      ) do
    :telemetry.detach(handler)

    TeamMember.load!(%{team_id: team_id, maintainer_id: maintainer_id},
      return_notifications?: true
    )

    send(parent, :team_deletion_blocked)
  end

  def block_team_deletion(_event, _measurements, _metadata, _config), do: :ok

  defp snapshot(package) do
    %MetadataSnapshot{
      package_ids: %{"metadata-test" => package},
      maintainers: %{
        11 => %{github_id: 11, github: "alice"},
        22 => %{github_id: 22, github: "bob"}
      },
      teams: %{
        "team" => %{
          short_name: "team",
          scope: "scope",
          github: "team",
          github_id: 44,
          member_github_ids: [22]
        }
      },
      joins: %{"metadata-test" => %{maintainer_github_ids: [11], team_short_names: ["team"]}}
    }
  end

  defp empty do
    %MetadataSnapshot{package_ids: %{}, maintainers: %{}, teams: %{}, joins: %{}}
  end

  defp state(channel) do
    {Channel.by_id!(channel.id),
     Enum.map(
       [Maintainer, Team, PackageMaintainer, TeamMember, PackageTeam],
       & &1.read!(query: [sort: :id])
     )}
  end
end

defmodule Tracker.Nixpkgs.TeamTest do
  use Tracker.DataCase, async: true

  alias Tracker.Nixpkgs.{
    Channel,
    ChannelRevision,
    Package,
    PackageRevision,
    PackageTeam,
    Team
  }

  describe "list/2 channel filtering" do
    setup do
      channel =
        Channel.create!(%{
          name: "nixos-unstable",
          display_name: "nixos-unstable",
          branch: "nixos-unstable",
          status: :active,
          is_stable: false
        })

      cr =
        ChannelRevision
        |> Ash.Changeset.for_create(:create, %{
          channel_id: channel.id,
          revision: "aaa1111",
          released_at: ~U[2025-01-01 00:00:00Z]
        })
        |> Ash.create!()

      team_in =
        Team
        |> Ash.Changeset.for_create(:bulk_upsert, %{short_name: "team-in"})
        |> Ash.create!()

      team_out =
        Team
        |> Ash.Changeset.for_create(:bulk_upsert, %{short_name: "team-out"})
        |> Ash.create!()

      pkg_in =
        Package.bulk_upsert_all([%{attribute: "team-in-pkg"}])
        |> Map.fetch!("team-in-pkg")
        |> then(&Ash.get!(Package, &1))

      pkg_out =
        Package.bulk_upsert_all([%{attribute: "team-out-pkg"}])
        |> Map.fetch!("team-out-pkg")
        |> then(&Ash.get!(Package, &1))

      # Only pkg_in has a revision in the channel
      PackageRevision
      |> Ash.Changeset.for_create(:load, %{
        version: "1.0",
        package_id: pkg_in.id,
        channel_revision_id: cr.id
      })
      |> Ash.create!()

      # Link teams to their respective packages
      PackageTeam.load!(%{package_id: pkg_in.id, team_id: team_in.id})
      PackageTeam.load!(%{package_id: pkg_out.id, team_id: team_out.id})

      %{channel: channel, team_in: team_in, team_out: team_out}
    end

    test "without channel_id returns all teams", %{team_in: team_in, team_out: team_out} do
      page = Team.list!(nil, nil, page: [count: true])

      names = Enum.map(page.results, &to_string(&1.short_name))
      assert to_string(team_in.short_name) in names
      assert to_string(team_out.short_name) in names
    end

    test "with channel_id returns only teams with packages in that channel", %{
      channel: channel,
      team_in: team_in,
      team_out: team_out
    } do
      page = Team.list!(nil, channel.id, page: [count: true])

      names = Enum.map(page.results, &to_string(&1.short_name))
      assert to_string(team_in.short_name) in names
      refute to_string(team_out.short_name) in names
    end
  end
end

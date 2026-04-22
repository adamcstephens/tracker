defmodule Tracker.Nixpkgs.ChangeTest do
  use Tracker.DataCase, async: true

  alias Tracker.Nixpkgs.{Change, Channel, ChannelRevision, Package}

  describe "bulk_upsert_all/1" do
    test "returns a map of number to id" do
      records = [
        %{
          number: 1001,
          title: "fix: something",
          state: :open,
          author: "alice",
          url: "https://github.com/NixOS/nixpkgs/pull/1001"
        },
        %{
          number: 1002,
          title: "feat: add thing",
          state: :merged,
          author: "bob",
          url: "https://github.com/NixOS/nixpkgs/pull/1002"
        }
      ]

      id_map = Change.bulk_upsert_all(records)

      assert is_map(id_map)
      assert map_size(id_map) == 2
      assert is_integer(id_map[1001])
      assert is_integer(id_map[1002])
    end

    test "upserts existing records by number" do
      Change.bulk_upsert_all([
        %{
          number: 2001,
          title: "old title",
          state: :open,
          author: "alice",
          url: "https://github.com/NixOS/nixpkgs/pull/2001"
        }
      ])

      id_map =
        Change.bulk_upsert_all([
          %{
            number: 2001,
            title: "new title",
            state: :merged,
            author: "alice",
            url: "https://github.com/NixOS/nixpkgs/pull/2001"
          }
        ])

      assert map_size(id_map) == 1
      change = Ash.get!(Change, id_map[2001])
      assert change.title == "new title"
      assert change.state == :merged
    end

    test "stores additional metadata fields" do
      id_map =
        Change.bulk_upsert_all([
          %{
            number: 4001,
            title: "nixos/incus: add useACMEHost option",
            state: :merged,
            author: "herbetom",
            author_github_id: 1234,
            merged_by_github_id: 5678,
            url: "https://github.com/NixOS/nixpkgs/pull/4001",
            base_ref: "master",
            labels: ["6.topic: nixos", "8.has: module (update)", "backport release-25.11"],
            merge_commit_sha: "abc123def456",
            gh_created_at: ~U[2026-03-28 16:15:06Z],
            merged_at: ~U[2026-03-31 01:57:58Z]
          }
        ])

      change = Ash.get!(Change, id_map[4001])
      assert change.author_github_id == 1234
      assert change.merged_by_github_id == 5678
      assert change.base_ref == "master"

      assert change.labels == [
               "6.topic: nixos",
               "8.has: module (update)",
               "backport release-25.11"
             ]

      assert change.merge_commit_sha == "abc123def456"
    end
  end

  describe "list/3 channel filtering" do
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

      change_in_id =
        Change.bulk_upsert_all([
          %{
            number: 5001,
            title: "in-channel change",
            state: :merged,
            author: "alice",
            url: "https://github.com/NixOS/nixpkgs/pull/5001"
          }
        ])
        |> Map.fetch!(5001)

      change_out_id =
        Change.bulk_upsert_all([
          %{
            number: 5002,
            title: "out-channel change",
            state: :merged,
            author: "bob",
            url: "https://github.com/NixOS/nixpkgs/pull/5002"
          }
        ])
        |> Map.fetch!(5002)

      Tracker.Nixpkgs.ChangeChannel
      |> Ash.Changeset.for_create(:create, %{
        change_id: change_in_id,
        channel_id: channel.id,
        channel_revision_id: cr.id,
        landed_at: ~U[2025-01-01 10:00:00Z]
      })
      |> Ash.create!()

      %{channel: channel, change_in_id: change_in_id, change_out_id: change_out_id}
    end

    test "without channel_id returns all changes", %{
      change_in_id: change_in_id,
      change_out_id: change_out_id
    } do
      page = Change.list!(nil, nil, nil, page: [count: true])

      ids = Enum.map(page.results, & &1.id)
      assert change_in_id in ids
      assert change_out_id in ids
    end

    test "with channel_id returns only changes in that channel", %{
      channel: channel,
      change_in_id: change_in_id,
      change_out_id: change_out_id
    } do
      page = Change.list!(nil, nil, channel.id, page: [count: true])

      ids = Enum.map(page.results, & &1.id)
      assert change_in_id in ids
      refute change_out_id in ids
    end
  end

  describe "PR lifecycle fields" do
    test "accepts :draft state" do
      id_map =
        Change.bulk_upsert_all([
          %{
            number: 6001,
            title: "wip: draft pr",
            state: :draft,
            author: "alice",
            url: "https://github.com/NixOS/nixpkgs/pull/6001"
          }
        ])

      change = Ash.get!(Change, id_map[6001])
      assert change.state == :draft
    end

    test "accepts :too_large processing_status" do
      id_map =
        Change.bulk_upsert_all([
          %{
            number: 6002,
            title: "massive refactor",
            state: :merged,
            author: "bob",
            url: "https://github.com/NixOS/nixpkgs/pull/6002",
            processing_status: :too_large
          }
        ])

      change = Ash.get!(Change, id_map[6002])
      assert change.processing_status == :too_large
    end

    test "stores lifecycle tracking fields" do
      id_map =
        Change.bulk_upsert_all([
          %{
            number: 6003,
            title: "tracked",
            state: :open,
            author: "carol",
            url: "https://github.com/NixOS/nixpkgs/pull/6003",
            node_id: "PR_kwDOAEVQ_M6ABCxyZ",
            head_sha: "deadbeef1234567890deadbeef12345678901234",
            gh_updated_at: ~U[2026-04-20 12:00:00Z],
            last_checked_at: ~U[2026-04-21 08:00:00.123456Z],
            closed_at: ~U[2026-04-22 08:00:00Z]
          }
        ])

      change = Ash.get!(Change, id_map[6003])
      assert change.node_id == "PR_kwDOAEVQ_M6ABCxyZ"
      assert change.head_sha == "deadbeef1234567890deadbeef12345678901234"
      assert change.gh_updated_at == ~U[2026-04-20 12:00:00Z]
      assert change.last_checked_at == ~U[2026-04-21 08:00:00.123456Z]
      assert change.closed_at == ~U[2026-04-22 08:00:00Z]
    end

    test "upsert refreshes lifecycle fields on subsequent calls" do
      Change.bulk_upsert_all([
        %{
          number: 6005,
          title: "evolving",
          state: :draft,
          author: "erin",
          url: "https://github.com/NixOS/nixpkgs/pull/6005",
          node_id: "PR_node_6005",
          head_sha: "aaaa1111",
          gh_updated_at: ~U[2026-04-20 12:00:00Z]
        }
      ])

      id_map =
        Change.bulk_upsert_all([
          %{
            number: 6005,
            title: "evolving",
            state: :open,
            author: "erin",
            url: "https://github.com/NixOS/nixpkgs/pull/6005",
            node_id: "PR_node_6005",
            head_sha: "bbbb2222",
            gh_updated_at: ~U[2026-04-21 12:00:00Z],
            last_checked_at: ~U[2026-04-21 12:01:00.000000Z]
          }
        ])

      change = Ash.get!(Change, id_map[6005])
      assert change.state == :open
      assert change.head_sha == "bbbb2222"
      assert change.gh_updated_at == ~U[2026-04-21 12:00:00Z]
      assert change.last_checked_at == ~U[2026-04-21 12:01:00.000000Z]
    end
  end

  describe "get_by_node_id/1" do
    test "returns the change" do
      Change.bulk_upsert_all([
        %{
          number: 6004,
          title: "by node id",
          state: :open,
          author: "dave",
          url: "https://github.com/NixOS/nixpkgs/pull/6004",
          node_id: "PR_node_6004"
        }
      ])

      assert {:ok, change} = Change.get_by_node_id("PR_node_6004")
      assert change.number == 6004
    end

    test "returns error for unknown node_id" do
      assert {:error, _} = Change.get_by_node_id("PR_does_not_exist")
    end
  end

  describe "relationships" do
    test "can link to packages via change_packages" do
      id_map =
        Change.bulk_upsert_all([
          %{
            number: 3001,
            title: "update curl",
            state: :merged,
            author: "alice",
            url: "https://github.com/NixOS/nixpkgs/pull/3001"
          }
        ])

      pkg_map = Package.bulk_upsert_all([%{attribute: "curl"}])

      change_id = id_map[3001]
      package_id = pkg_map["curl"]

      Tracker.Nixpkgs.ChangePackage.bulk_create_all([
        %{change_id: change_id, package_id: package_id, type: :changed}
      ])

      change =
        Ash.get!(Change, change_id)
        |> Ash.load!(:packages)

      assert length(change.packages) == 1
      assert hd(change.packages).id == package_id
    end
  end
end

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

    test "does not reset processing_status on upsert of an existing row" do
      # Discovery-style payload: no :processing_status key.
      payload = %{
        number: 2100,
        title: "some PR",
        state: :merged,
        author: "alice",
        url: "https://github.com/NixOS/nixpkgs/pull/2100"
      }

      id_map = Change.bulk_upsert_all([payload])
      change = Ash.get!(Change, id_map[2100])

      # Artifact pipeline sets status terminal.
      Change.update_processing_status!(change, %{processing_status: :processed})

      # Later discovery pass upserts the same row again (same discovery-style
      # payload, no :processing_status). Status must survive.
      Change.bulk_upsert_all([payload])

      refreshed = Ash.get!(Change, id_map[2100])
      assert refreshed.processing_status == :processed
    end

    test "sets processing_status to :pending on insert of a new row" do
      payload = %{
        number: 2200,
        title: "fresh PR",
        state: :open,
        author: "bob",
        url: "https://github.com/NixOS/nixpkgs/pull/2200"
      }

      id_map = Change.bulk_upsert_all([payload])
      change = Ash.get!(Change, id_map[2200])
      assert change.processing_status == :pending
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
          name: "nixos-26.52",
          display_name: "nixos-26.52",
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

      Tracker.Nixpkgs.ChangeBranch.create!(%{
        change_id: change_in_id,
        branch_name: "nixos-26.52",
        channel_revision_id: cr.id
      })

      %{channel: channel, change_in_id: change_in_id, change_out_id: change_out_id}
    end

    test "without channel_name returns all changes", %{
      change_in_id: change_in_id,
      change_out_id: change_out_id
    } do
      page = Change.list!(nil, nil, nil, page: [count: true])

      ids = Enum.map(page.results, & &1.id)
      assert change_in_id in ids
      assert change_out_id in ids
    end

    test "with channel_name returns only changes in that channel", %{
      channel: channel,
      change_in_id: change_in_id,
      change_out_id: change_out_id
    } do
      page = Change.list!(nil, nil, channel.name, page: [count: true])

      ids = Enum.map(page.results, & &1.id)
      assert change_in_id in ids
      refute change_out_id in ids
    end
  end

  describe "list/3 number search" do
    setup do
      channel =
        Channel.create!(%{
          name: "nixos-26.52",
          display_name: "nixos-26.52",
          status: :active,
          is_stable: false
        })

      cr =
        ChannelRevision
        |> Ash.Changeset.for_create(:create, %{
          channel_id: channel.id,
          revision: "bbb2222",
          released_at: ~U[2025-01-01 00:00:00Z]
        })
        |> Ash.create!()

      id_map =
        Change.bulk_upsert_all([
          %{
            number: 6101,
            title: "first change",
            state: :merged,
            author: "alice",
            base_ref: "master",
            url: "https://github.com/NixOS/nixpkgs/pull/6101"
          },
          %{
            number: 6102,
            title: "second change",
            state: :merged,
            author: "bob",
            base_ref: "master",
            url: "https://github.com/NixOS/nixpkgs/pull/6102"
          }
        ])

      Tracker.Nixpkgs.ChangeBranch.create!(%{
        change_id: Map.fetch!(id_map, 6101),
        branch_name: "nixos-26.52",
        channel_revision_id: cr.id
      })

      %{
        channel: channel,
        first_id: Map.fetch!(id_map, 6101),
        second_id: Map.fetch!(id_map, 6102)
      }
    end

    test "matches the exact PR number", %{first_id: first_id, second_id: second_id} do
      page = Change.list!("6101", nil, nil, page: [count: true])

      ids = Enum.map(page.results, & &1.id)
      assert first_id in ids
      refute second_id in ids
    end

    test "does not prefix-match numbers" do
      page = Change.list!("610", nil, nil, page: [count: true])

      assert page.results == []
    end

    test "bypasses the channel filter", %{channel: channel, second_id: second_id} do
      page = Change.list!("6102", nil, channel.name, page: [count: true])

      assert [%{id: ^second_id}] = page.results
    end

    test "bypasses the base_ref filter", %{first_id: first_id} do
      page = Change.list!("6101", "release-25.11", nil, page: [count: true])

      assert [%{id: ^first_id}] = page.results
    end

    test "non-numeric search still matches titles", %{first_id: first_id, second_id: second_id} do
      page = Change.list!("first", nil, nil, page: [count: true])

      ids = Enum.map(page.results, & &1.id)
      assert first_id in ids
      refute second_id in ids
    end

    test "mixed alphanumeric search does not exact-match numbers" do
      page = Change.list!("61x1", nil, nil, page: [count: true])

      assert page.results == []
    end

    test "digit strings beyond integer range do not crash" do
      page = Change.list!("99999999999", nil, nil, page: [count: true])

      assert page.results == []
    end
  end

  describe "list/3 text search" do
    setup do
      %{
        closest: merged_change!(%{number: 7101, title: "go_1_26: 1.26.6 -> 1.26.7"}),
        looser: merged_change!(%{number: 7199, title: "gomarkdoc: restore checks on Go 1.26"}),
        unrelated: [
          merged_change!(%{number: 7301, title: "flashrom: 1.7.0 -> 1.8.0"}),
          merged_change!(%{number: 7302, title: "go_1_25: 1.25.13 -> 1.25.14"}),
          merged_change!(%{number: 7303, title: "berglas: 1.26.3 -> 1.26.6"})
        ]
      }
    end

    test "ranks the closest title first even when it has the lowest number" do
      page =
        Change.list!("go 1.26.7", nil, nil, query: [sort: [number: :desc]], page: [count: true])

      assert [%{number: 7101}, %{number: 7199} | _] = page.results
    end

    test "requires every search token to match", %{unrelated: unrelated} do
      page = Change.list!("go 1.26.7", nil, nil, page: [count: true])

      numbers = Enum.map(page.results, & &1.number)

      for change <- unrelated do
        refute change.number in numbers
      end
    end

    test "a two character token matches whole words but not substrings" do
      word = merged_change!(%{number: 7501, title: "go_1_26: 1.26.6 -> 1.26.7"})
      substring = merged_change!(%{number: 7502, title: "mongodb: 8.0.3 -> 8.0.4"})

      page = Change.list!("go", nil, nil, page: [count: true])

      numbers = Enum.map(page.results, & &1.number)
      assert word.number in numbers
      refute substring.number in numbers
    end

    test "a single token search still matches on the author" do
      change = merged_change!(%{number: 7401, title: "hello: 1.0 -> 1.1", author: "nixpkgs-ci"})

      page = Change.list!("nixpkgs-ci", nil, nil, page: [count: true])

      assert change.number in Enum.map(page.results, & &1.number)
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

  describe "in_flight_propagation/0" do
    test "excludes changes whose recorded branches cover base_ref and every terminal channel" do
      change = merged_change!(base_ref: "master")

      record_branches!(change, ~w(master nixos-unstable nixos-unstable-small nixpkgs-unstable))

      refute change.id in in_flight_ids()
    end

    test "includes a change still missing one terminal channel" do
      change = merged_change!(base_ref: "master")

      record_branches!(change, ~w(master nixos-unstable nixos-unstable-small))

      assert change.id in in_flight_ids()
    end

    test "includes a change that has not recorded its own base_ref" do
      change = merged_change!(base_ref: "staging")

      assert change.id in in_flight_ids()
    end

    test "excludes changes whose base_ref is outside the propagation graph" do
      change = merged_change!(base_ref: "wip-home-assistant")

      refute change.id in in_flight_ids()
    end

    test "excludes changes that are not merged or have no merge_commit_sha" do
      open = merged_change!(base_ref: "master", state: :open)
      unmerged = merged_change!(base_ref: "master", merge_commit_sha: nil)

      ids = in_flight_ids()

      refute open.id in ids
      refute unmerged.id in ids
    end

    test "covers a release line against its own versioned channels" do
      change = merged_change!(base_ref: "release-26.05")

      record_branches!(change, ~w(release-26.05 nixos-26.05 nixos-26.05-small))
      assert change.id in in_flight_ids()

      record_branches!(change, ~w(nixpkgs-26.05-darwin))
      refute change.id in in_flight_ids()
    end
  end

  defp in_flight_ids do
    Change.in_flight_propagation!() |> Enum.map(& &1.id)
  end

  defp merged_change!(attrs) do
    number = System.unique_integer([:positive])

    record =
      Map.merge(
        %{
          number: number,
          title: "PR ##{number}",
          state: :merged,
          author: "tester",
          url: "https://github.com/NixOS/nixpkgs/pull/#{number}",
          merged_at: ~U[2026-04-23 10:00:00Z],
          merge_commit_sha: "deadbeef#{number}"
        },
        Map.new(attrs)
      )

    Change.bulk_upsert_all([record])
    Change.get_by_number!(record.number)
  end

  defp record_branches!(change, branches) do
    for branch <- branches do
      Tracker.Nixpkgs.ChangeBranch.create!(%{change_id: change.id, branch_name: branch})
    end
  end
end

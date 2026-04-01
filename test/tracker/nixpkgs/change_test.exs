defmodule Tracker.Nixpkgs.ChangeTest do
  use Tracker.DataCase, async: true

  alias Tracker.Nixpkgs.Change
  alias Tracker.Nixpkgs.Package

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
        %{change_id: change_id, package_id: package_id}
      ])

      change =
        Ash.get!(Change, change_id)
        |> Ash.load!(:packages)

      assert length(change.packages) == 1
      assert hd(change.packages).id == package_id
    end
  end
end

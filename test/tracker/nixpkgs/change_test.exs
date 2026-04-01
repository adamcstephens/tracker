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

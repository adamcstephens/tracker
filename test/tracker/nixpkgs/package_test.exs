defmodule Tracker.Nixpkgs.PackageTest do
  use Tracker.DataCase, async: true

  alias Tracker.Nixpkgs.Package

  describe "bulk_upsert_all/1" do
    test "returns a map of attribute to id" do
      records = [
        %{attribute: "hello"},
        %{attribute: "curl"},
        %{attribute: "git"}
      ]

      id_map = Package.bulk_upsert_all(records)

      assert is_map(id_map)
      assert map_size(id_map) == 3
      assert is_integer(id_map["hello"])
      assert is_integer(id_map["curl"])
      assert is_integer(id_map["git"])
    end

    test "returns ids for upserted (existing) records" do
      Package.bulk_upsert_all([%{attribute: "vim", description: "old"}])

      id_map = Package.bulk_upsert_all([%{attribute: "vim", description: "new"}])

      assert map_size(id_map) == 1
      assert is_integer(id_map["vim"])

      package = Ash.get!(Package, %{attribute: "vim"})
      assert package.id == id_map["vim"]
      assert package.description == "new"
    end

    test "accumulates ids across chunks" do
      # Generate enough records to span multiple chunks
      records = for i <- 1..7000, do: %{attribute: "chunk-pkg-#{i}"}

      id_map = Package.bulk_upsert_all(records)

      assert map_size(id_map) == 7000
      assert Enum.all?(id_map, fn {_attr, id} -> is_integer(id) end)
    end
  end
end

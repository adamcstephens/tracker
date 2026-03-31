defmodule Tracker.Nixpkgs.PackageFamilyTest do
  use Tracker.DataCase, async: true

  alias Tracker.Nixpkgs.PackageFamily

  describe "bulk_upsert_all/1" do
    test "returns a map of {name, ecosystem} to id" do
      records = [
        %{name: "numpy", ecosystem: "python"},
        %{name: "requests", ecosystem: "python"},
        %{name: "lodash", ecosystem: "node"}
      ]

      id_map = PackageFamily.bulk_upsert_all(records)

      assert is_map(id_map)
      assert map_size(id_map) == 3
      assert is_integer(id_map[{"numpy", "python"}])
      assert is_integer(id_map[{"requests", "python"}])
      assert is_integer(id_map[{"lodash", "node"}])
    end

    test "returns ids for upserted (existing) records" do
      PackageFamily.bulk_upsert_all([%{name: "numpy", ecosystem: "python"}])

      id_map = PackageFamily.bulk_upsert_all([%{name: "numpy", ecosystem: "python"}])

      assert map_size(id_map) == 1
      assert is_integer(id_map[{"numpy", "python"}])
    end
  end
end

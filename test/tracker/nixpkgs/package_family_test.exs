defmodule Tracker.Nixpkgs.PackageFamilyTest do
  use Tracker.DataCase, async: true

  require Ash.Query

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

    test "writes rows in conflict-key order regardless of input order (deadlock guard)" do
      # Shared across channels; concurrent upserts deadlock unless every writer
      # locks rows in one global order (trk-330). Fresh rows' id order reveals
      # the write order.
      shuffled = [
        %{name: "zlib", ecosystem: "c"},
        %{name: "numpy", ecosystem: "python"},
        %{name: "numpy", ecosystem: "node"},
        %{name: "axios", ecosystem: "node"}
      ]

      PackageFamily.bulk_upsert_all(shuffled)

      keys = Enum.map(shuffled, &{&1.name, &1.ecosystem})

      ordered_by_id =
        PackageFamily
        |> Ash.Query.filter(name in ^Enum.map(shuffled, & &1.name))
        |> Ash.Query.sort(id: :asc)
        |> Ash.read!()
        |> Enum.map(&{&1.name, &1.ecosystem})

      assert ordered_by_id == Enum.sort(keys)
    end
  end
end

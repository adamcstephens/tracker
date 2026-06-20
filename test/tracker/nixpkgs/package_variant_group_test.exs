defmodule Tracker.Nixpkgs.PackageVariantGroupTest do
  use Tracker.DataCase, async: true

  require Ash.Query

  alias Tracker.Nixpkgs.PackageVariantGroup

  describe "bulk_upsert_all/1" do
    test "returns a map of position to id" do
      records = [
        %{position: "pkgs/development/libraries/ffmpeg/generic.nix:1054"},
        %{position: "pkgs/applications/science/logic/coq/default.nix:309"}
      ]

      id_map = PackageVariantGroup.bulk_upsert_all(records)

      assert is_map(id_map)
      assert map_size(id_map) == 2

      assert is_integer(id_map["pkgs/development/libraries/ffmpeg/generic.nix:1054"])

      assert is_integer(id_map["pkgs/applications/science/logic/coq/default.nix:309"])
    end

    test "returns ids for upserted (existing) records" do
      position = "pkgs/development/libraries/ffmpeg/generic.nix:1054"
      PackageVariantGroup.bulk_upsert_all([%{position: position}])

      id_map = PackageVariantGroup.bulk_upsert_all([%{position: position}])

      assert map_size(id_map) == 1
      assert is_integer(id_map[position])
    end

    test "returns empty map for empty input" do
      id_map = PackageVariantGroup.bulk_upsert_all([])
      assert id_map == %{}
    end

    test "writes rows in position order regardless of input order (deadlock guard)" do
      # Shared across channels; concurrent upserts deadlock unless every writer
      # locks rows in one global order (trk-330). Fresh rows' id order reveals
      # the write order.
      shuffled = ~w(
        pkgs/z/generic.nix:1
        pkgs/a/generic.nix:1
        pkgs/m/generic.nix:1
        pkgs/a/generic.nix:2
      )

      PackageVariantGroup.bulk_upsert_all(Enum.map(shuffled, &%{position: &1}))

      ordered_by_id =
        PackageVariantGroup
        |> Ash.Query.filter(position in ^shuffled)
        |> Ash.Query.sort(id: :asc)
        |> Ash.read!()
        |> Enum.map(& &1.position)

      assert ordered_by_id == Enum.sort(shuffled)
    end
  end
end

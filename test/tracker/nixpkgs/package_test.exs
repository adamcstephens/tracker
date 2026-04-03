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

  describe "by_module/1" do
    test "returns packages linked to options in the given module" do
      mod =
        Tracker.Nixpkgs.Module
        |> Ash.Changeset.for_create(:bulk_upsert, %{display_name: "services.bymod"})
        |> Ash.create!()

      pkg =
        Tracker.Nixpkgs.Package
        |> Ash.Changeset.for_create(:create, %{attribute: "bymod-pkg"})
        |> Ash.create!()

      option =
        Tracker.Nixpkgs.Option
        |> Ash.Changeset.for_create(:bulk_upsert, %{
          name: "services.bymod.enable",
          module_id: mod.id
        })
        |> Ash.create!()

      Tracker.Nixpkgs.OptionPackage.load!(%{
        option_id: option.id,
        package_id: pkg.id,
        module_id: mod.id
      })

      packages = Package.by_module!(mod.id)

      assert length(packages) == 1
      assert hd(packages).attribute == "bymod-pkg"
    end

    test "excludes packages from other modules" do
      mod1 =
        Tracker.Nixpkgs.Module
        |> Ash.Changeset.for_create(:bulk_upsert, %{display_name: "services.mod1"})
        |> Ash.create!()

      mod2 =
        Tracker.Nixpkgs.Module
        |> Ash.Changeset.for_create(:bulk_upsert, %{display_name: "services.mod2"})
        |> Ash.create!()

      pkg1 =
        Tracker.Nixpkgs.Package
        |> Ash.Changeset.for_create(:create, %{attribute: "mod1-pkg"})
        |> Ash.create!()

      pkg2 =
        Tracker.Nixpkgs.Package
        |> Ash.Changeset.for_create(:create, %{attribute: "mod2-pkg"})
        |> Ash.create!()

      opt1 =
        Tracker.Nixpkgs.Option
        |> Ash.Changeset.for_create(:bulk_upsert, %{
          name: "services.mod1.enable",
          module_id: mod1.id
        })
        |> Ash.create!()

      opt2 =
        Tracker.Nixpkgs.Option
        |> Ash.Changeset.for_create(:bulk_upsert, %{
          name: "services.mod2.enable",
          module_id: mod2.id
        })
        |> Ash.create!()

      Tracker.Nixpkgs.OptionPackage.load!(%{
        option_id: opt1.id,
        package_id: pkg1.id,
        module_id: mod1.id
      })

      Tracker.Nixpkgs.OptionPackage.load!(%{
        option_id: opt2.id,
        package_id: pkg2.id,
        module_id: mod2.id
      })

      packages = Package.by_module!(mod1.id)

      assert length(packages) == 1
      assert hd(packages).attribute == "mod1-pkg"
    end
  end
end

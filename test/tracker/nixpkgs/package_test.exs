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

    test "upsert without metadata fields preserves existing metadata" do
      Package.bulk_upsert_all([
        %{
          attribute: "curl",
          description: "A command line tool",
          homepage: ["https://curl.se"],
          position: "pkgs/tools/networking/curl/default.nix",
          licenses: ["MIT"]
        }
      ])

      # Upsert a batch without metadata fields (simulates non-metadata channel).
      # The batch must contain multiple records so Ecto unions the keys across
      # the chunk, causing missing keys to be inserted as NULL.
      Package.bulk_upsert_all([
        %{attribute: "curl", package_set: "top-level"},
        %{attribute: "wget"}
      ])

      package = Ash.get!(Package, %{attribute: "curl"})
      assert package.description == "A command line tool"
      assert package.homepage == ["https://curl.se"]
      assert package.position == "pkgs/tools/networking/curl/default.nix"
      assert package.licenses == ["MIT"]
      assert package.package_set == "top-level"
    end

    test "accumulates ids across chunks" do
      # Generate enough records to span multiple chunks
      records = for i <- 1..7000, do: %{attribute: "chunk-pkg-#{i}"}

      id_map = Package.bulk_upsert_all(records)

      assert map_size(id_map) == 7000
      assert Enum.all?(id_map, fn {_attr, id} -> is_integer(id) end)
    end
  end

  describe "variant_siblings/2" do
    test "returns packages in the same variant group, excluding self" do
      group =
        Tracker.Nixpkgs.PackageVariantGroup
        |> Ash.Changeset.for_create(:bulk_upsert, %{
          position: "pkgs/development/libraries/ffmpeg/generic.nix:1054"
        })
        |> Ash.create!()

      pkg1 =
        Package
        |> Ash.Changeset.for_create(:bulk_upsert, %{
          attribute: "ffmpeg_7",
          package_variant_group_id: group.id
        })
        |> Ash.create!()

      _pkg2 =
        Package
        |> Ash.Changeset.for_create(:bulk_upsert, %{
          attribute: "ffmpeg_8",
          package_variant_group_id: group.id
        })
        |> Ash.create!()

      _pkg3 =
        Package
        |> Ash.Changeset.for_create(:bulk_upsert, %{
          attribute: "ffmpeg_4",
          package_variant_group_id: group.id
        })
        |> Ash.create!()

      siblings = Package.variant_siblings!(group.id, pkg1.id)

      assert length(siblings) == 2
      attrs = Enum.map(siblings, & &1.attribute)
      assert "ffmpeg_8" in attrs
      assert "ffmpeg_4" in attrs
      refute "ffmpeg_7" in attrs
    end

    test "returns empty list when no variant group" do
      pkg =
        Package
        |> Ash.Changeset.for_create(:create, %{attribute: "solo-pkg"})
        |> Ash.create!()

      assert Package.variant_siblings!(0, pkg.id) == []
    end

    test "results are sorted by attribute" do
      group =
        Tracker.Nixpkgs.PackageVariantGroup
        |> Ash.Changeset.for_create(:bulk_upsert, %{
          position: "pkgs/test/sort.nix:1"
        })
        |> Ash.create!()

      pkg_c =
        Package
        |> Ash.Changeset.for_create(:bulk_upsert, %{
          attribute: "zz-variant-c",
          package_variant_group_id: group.id
        })
        |> Ash.create!()

      Package
      |> Ash.Changeset.for_create(:bulk_upsert, %{
        attribute: "aa-variant-a",
        package_variant_group_id: group.id
      })
      |> Ash.create!()

      Package
      |> Ash.Changeset.for_create(:bulk_upsert, %{
        attribute: "mm-variant-b",
        package_variant_group_id: group.id
      })
      |> Ash.create!()

      siblings = Package.variant_siblings!(group.id, pkg_c.id)

      assert Enum.map(siblings, & &1.attribute) == ["aa-variant-a", "mm-variant-b"]
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

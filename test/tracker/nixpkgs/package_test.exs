defmodule Tracker.Nixpkgs.PackageTest do
  use Tracker.DataCase, async: true

  require Ash.Query

  alias Tracker.Fixtures
  alias Tracker.Nixpkgs.{Channel, ChannelRevision, Package}

  defp create_channel!(name) do
    Channel.create!(%{
      name: name,
      display_name: name,
      status: :active,
      is_stable: false
    })
  end

  defp create_channel_revision!(channel_id, revision, released_at) do
    ChannelRevision
    |> Ash.Changeset.for_create(:create, %{
      channel_id: channel_id,
      revision: revision,
      released_at: released_at
    })
    |> Ash.create!()
  end

  defp create_package!(attribute) do
    Package.bulk_upsert_all([%{attribute: attribute}])
    |> Map.fetch!(attribute)
    |> then(&Ash.get!(Package, &1))
  end

  # Opens a package span so the package is "current" in the channel (the
  # `upper_inf` semi-join used by list/by_maintainer/by_team).
  defp create_revision!(package, channel_revision, version) do
    Fixtures.apply_package_revision!(channel_revision, [{package, version}])
  end

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

    test "returns the same id when upserting an existing attribute" do
      first = Package.bulk_upsert_all([%{attribute: "vim"}])
      id_map = Package.bulk_upsert_all([%{attribute: "vim"}])

      assert map_size(id_map) == 1
      assert id_map["vim"] == first["vim"]

      package = Ash.get!(Package, %{attribute: "vim"})
      assert package.id == id_map["vim"]
    end

    test "upserts family and variant FKs (identity-only, no metadata)" do
      group =
        Tracker.Nixpkgs.PackageVariantGroup
        |> Ash.Changeset.for_create(:bulk_upsert, %{position: "pkgs/test/curl.nix:1"})
        |> Ash.create!()

      Package.bulk_upsert_all([%{attribute: "curl"}])
      id_map = Package.bulk_upsert_all([%{attribute: "curl", package_variant_group_id: group.id}])

      package = Ash.get!(Package, id_map["curl"])
      assert package.package_variant_group_id == group.id
      refute Map.has_key?(package, :description)
    end

    test "writes rows in attribute order regardless of input order (deadlock guard)" do
      # Concurrent channel ingestions upsert the shared `packages` table; if each
      # writer locks rows in a different order they deadlock (trk-330). Sorting by
      # the conflict key gives every writer one global lock order. A single
      # INSERT assigns bigserial ids in VALUES order, so fresh rows' id order
      # reveals the write order.
      shuffled = ~w(dlg-mango dlg-apple dlg-cherry dlg-banana dlg-date)
      Package.bulk_upsert_all(Enum.map(shuffled, &%{attribute: &1}))

      ordered_by_id =
        Package
        |> Ash.Query.filter(attribute in ^shuffled)
        |> Ash.Query.sort(id: :asc)
        |> Ash.read!()
        |> Enum.map(& &1.attribute)

      assert ordered_by_id == Enum.sort(shuffled)
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

  describe "list/2 channel filtering" do
    setup do
      channel = create_channel!("nixos-unstable")
      cr = create_channel_revision!(channel.id, "aaa1111", ~U[2025-01-01 00:00:00Z])

      pkg_in = create_package!("in-channel-pkg")
      pkg_out = create_package!("out-channel-pkg")

      create_revision!(pkg_in, cr, "1.0")

      %{channel: channel, pkg_in: pkg_in, pkg_out: pkg_out}
    end

    test "without channel_id returns all packages", %{pkg_in: pkg_in, pkg_out: pkg_out} do
      page = Package.list!(nil, nil, page: [count: true])

      attrs = Enum.map(page.results, & &1.attribute)
      assert pkg_in.attribute in attrs
      assert pkg_out.attribute in attrs
    end

    test "with channel_id returns only packages in that channel", %{
      channel: channel,
      pkg_in: pkg_in,
      pkg_out: pkg_out
    } do
      page = Package.list!(nil, channel.id, page: [count: true])

      attrs = Enum.map(page.results, & &1.attribute)
      assert pkg_in.attribute in attrs
      refute pkg_out.attribute in attrs
    end
  end

  describe "by_maintainer/3 channel filtering" do
    setup do
      channel = create_channel!("nixos-unstable")
      cr = create_channel_revision!(channel.id, "bbb2222", ~U[2025-01-01 00:00:00Z])

      maintainer =
        Tracker.Nixpkgs.Maintainer
        |> Ash.Changeset.for_create(:bulk_upsert, %{github_id: 12345, github: "testmaint"})
        |> Ash.create!()

      pkg_in = create_package!("maint-in-pkg")
      pkg_out = create_package!("maint-out-pkg")

      create_revision!(pkg_in, cr, "1.0")

      for pkg <- [pkg_in, pkg_out] do
        Tracker.Nixpkgs.PackageMaintainer.load!(%{
          package_id: pkg.id,
          maintainer_id: maintainer.id
        })
      end

      %{channel: channel, maintainer: maintainer, pkg_in: pkg_in, pkg_out: pkg_out}
    end

    test "without channel_id returns all maintainer packages", %{
      maintainer: maintainer,
      pkg_in: pkg_in,
      pkg_out: pkg_out
    } do
      page = Package.by_maintainer!(maintainer.id, nil, nil, page: [count: true])

      attrs = Enum.map(page.results, & &1.attribute)
      assert pkg_in.attribute in attrs
      assert pkg_out.attribute in attrs
    end

    test "with channel_id returns only maintainer packages in that channel", %{
      channel: channel,
      maintainer: maintainer,
      pkg_in: pkg_in,
      pkg_out: pkg_out
    } do
      page = Package.by_maintainer!(maintainer.id, nil, channel.id, page: [count: true])

      attrs = Enum.map(page.results, & &1.attribute)
      assert pkg_in.attribute in attrs
      refute pkg_out.attribute in attrs
    end
  end

  describe "by_team/3 channel filtering" do
    setup do
      channel = create_channel!("nixos-unstable")
      cr = create_channel_revision!(channel.id, "ccc3333", ~U[2025-01-01 00:00:00Z])

      team =
        Tracker.Nixpkgs.Team
        |> Ash.Changeset.for_create(:bulk_upsert, %{short_name: "testteam"})
        |> Ash.create!()

      pkg_in = create_package!("team-in-pkg")
      pkg_out = create_package!("team-out-pkg")

      create_revision!(pkg_in, cr, "1.0")

      for pkg <- [pkg_in, pkg_out] do
        Tracker.Nixpkgs.PackageTeam.load!(%{
          package_id: pkg.id,
          team_id: team.id
        })
      end

      %{channel: channel, team: team, pkg_in: pkg_in, pkg_out: pkg_out}
    end

    test "without channel_id returns all team packages", %{
      team: team,
      pkg_in: pkg_in,
      pkg_out: pkg_out
    } do
      page = Package.by_team!(team.id, nil, nil, page: [count: true])

      attrs = Enum.map(page.results, & &1.attribute)
      assert pkg_in.attribute in attrs
      assert pkg_out.attribute in attrs
    end

    test "with channel_id returns only team packages in that channel", %{
      channel: channel,
      team: team,
      pkg_in: pkg_in,
      pkg_out: pkg_out
    } do
      page = Package.by_team!(team.id, nil, channel.id, page: [count: true])

      attrs = Enum.map(page.results, & &1.attribute)
      assert pkg_in.attribute in attrs
      refute pkg_out.attribute in attrs
    end
  end
end

defmodule Tracker.Nixpkgs.PackageRevisionTest do
  use Tracker.DataCase, async: true

  alias Tracker.Nixpkgs.{Channel, ChannelRevision, Package, PackageRevision}

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

  defp create_revision!(package, channel_revision, version) do
    PackageRevision
    |> Ash.Changeset.for_create(:load, %{
      version: version,
      package_id: package.id,
      channel_revision_id: channel_revision.id
    })
    |> Ash.create!()
  end

  describe "version_changes_by_package/1" do
    setup do
      channel = create_channel!("unstable")
      pkg = create_package!("test-pkg")

      cr1 = create_channel_revision!(channel.id, "aaa1111", ~U[2025-01-01 00:00:00Z])
      cr2 = create_channel_revision!(channel.id, "bbb2222", ~U[2025-01-02 00:00:00Z])
      cr3 = create_channel_revision!(channel.id, "ccc3333", ~U[2025-01-03 00:00:00Z])
      cr4 = create_channel_revision!(channel.id, "ddd4444", ~U[2025-01-04 00:00:00Z])

      # Version changes: 1.0 -> 1.0 (same) -> 1.1 -> 1.1 (same)
      create_revision!(pkg, cr1, "1.0")
      create_revision!(pkg, cr2, "1.0")
      create_revision!(pkg, cr3, "1.1")
      create_revision!(pkg, cr4, "1.1")

      %{pkg: pkg}
    end

    test "returns only revisions where version changed", %{pkg: pkg} do
      {results, count} = PackageRevision.version_changes_by_package(pkg.id)

      assert count == 2
      assert length(results) == 2

      versions = Enum.map(results, & &1.version)
      assert "1.0" in versions
      assert "1.1" in versions
    end

    test "sorts by released_at desc by default", %{pkg: pkg} do
      {results, _count} = PackageRevision.version_changes_by_package(pkg.id)

      assert [first, second] = results
      assert first.version == "1.1"
      assert second.version == "1.0"
    end

    test "filters by channel" do
      unstable_ch = create_channel!("unstable-multi")
      stable_ch = create_channel!("stable-multi")
      pkg = create_package!("multi-channel-pkg")

      cr_u1 = create_channel_revision!(unstable_ch.id, "uuu1111", ~U[2025-02-01 00:00:00Z])
      cr_u2 = create_channel_revision!(unstable_ch.id, "uuu2222", ~U[2025-02-02 00:00:00Z])
      cr_s1 = create_channel_revision!(stable_ch.id, "sss1111", ~U[2025-02-01 00:00:00Z])

      create_revision!(pkg, cr_u1, "1.0")
      create_revision!(pkg, cr_u2, "1.1")
      create_revision!(pkg, cr_s1, "1.0")

      {results, count} =
        PackageRevision.version_changes_by_package(pkg.id, channel_id: unstable_ch.id)

      assert count == 2
      channels = results |> Enum.map(& &1.channel_name) |> Enum.uniq()
      assert channels == ["unstable-multi"]
    end

    test "filters by version substring" do
      ver_channel = create_channel!("unstable-ver")
      pkg = create_package!("version-filter-pkg")

      cr1 = create_channel_revision!(ver_channel.id, "vvv1111", ~U[2025-03-01 00:00:00Z])
      cr2 = create_channel_revision!(ver_channel.id, "vvv2222", ~U[2025-03-02 00:00:00Z])

      create_revision!(pkg, cr1, "1.0.0")
      create_revision!(pkg, cr2, "2.0.0")

      {results, count} = PackageRevision.version_changes_by_package(pkg.id, version: "2.0")

      assert count == 1
      assert hd(results).version == "2.0.0"
    end

    test "paginates with limit and offset" do
      pag_channel = create_channel!("unstable-pag")
      pkg = create_package!("paginated-pkg")

      for i <- 1..5 do
        cr =
          create_channel_revision!(
            pag_channel.id,
            "pag#{String.pad_leading(to_string(i), 4, "0")}",
            DateTime.add(~U[2025-04-01 00:00:00Z], i, :day)
          )

        create_revision!(pkg, cr, "#{i}.0")
      end

      {results, count} = PackageRevision.version_changes_by_package(pkg.id, limit: 2, offset: 0)
      assert count == 5
      assert length(results) == 2

      {results2, count2} = PackageRevision.version_changes_by_package(pkg.id, limit: 2, offset: 2)
      assert count2 == 5
      assert length(results2) == 2

      # No overlap
      ids1 = MapSet.new(results, & &1.id)
      ids2 = MapSet.new(results2, & &1.id)
      assert MapSet.disjoint?(ids1, ids2)
    end

    test "supports sorting by version asc" do
      sort_channel = create_channel!("unstable-sort")
      pkg = create_package!("sort-pkg")

      cr1 = create_channel_revision!(sort_channel.id, "sort1111", ~U[2025-05-01 00:00:00Z])
      cr2 = create_channel_revision!(sort_channel.id, "sort2222", ~U[2025-05-02 00:00:00Z])

      create_revision!(pkg, cr1, "beta")
      create_revision!(pkg, cr2, "alpha")

      {results, _} =
        PackageRevision.version_changes_by_package(pkg.id, sort_by: :version, sort_dir: :asc)

      assert [first, second] = results
      assert first.version == "alpha"
      assert second.version == "beta"
    end

    test "detects version changes per channel independently" do
      unstable_ic = create_channel!("unstable-ic")
      stable_ic = create_channel!("stable-ic")
      pkg = create_package!("independent-channels-pkg")

      cr_u1 = create_channel_revision!(unstable_ic.id, "ic_u1", ~U[2025-06-01 00:00:00Z])
      cr_u2 = create_channel_revision!(unstable_ic.id, "ic_u2", ~U[2025-06-02 00:00:00Z])
      cr_s1 = create_channel_revision!(stable_ic.id, "ic_s1", ~U[2025-06-01 00:00:00Z])
      cr_s2 = create_channel_revision!(stable_ic.id, "ic_s2", ~U[2025-06-02 00:00:00Z])

      # unstable: 1.0 -> 1.0 (no change)
      create_revision!(pkg, cr_u1, "1.0")
      create_revision!(pkg, cr_u2, "1.0")

      # stable: 1.0 -> 2.0 (change)
      create_revision!(pkg, cr_s1, "1.0")
      create_revision!(pkg, cr_s2, "2.0")

      {results, count} = PackageRevision.version_changes_by_package(pkg.id)

      # unstable: first appearance of 1.0
      # stable: first appearance of 1.0, then change to 2.0
      assert count == 3

      stable_results = Enum.filter(results, &(&1.channel_name == "stable-ic"))
      assert length(stable_results) == 2

      unstable_results = Enum.filter(results, &(&1.channel_name == "unstable-ic"))
      assert length(unstable_results) == 1
    end

    test "returns empty for package with no revisions" do
      pkg = create_package!("empty-pkg")

      {results, count} = PackageRevision.version_changes_by_package(pkg.id)

      assert results == []
      assert count == 0
    end
  end
end

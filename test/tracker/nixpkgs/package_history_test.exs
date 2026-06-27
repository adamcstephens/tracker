defmodule Tracker.Nixpkgs.PackageHistoryTest do
  use Tracker.DataCase, async: true

  alias Tracker.Fixtures
  alias Tracker.Nixpkgs.{ChannelRevision, PackageHistory}

  defp revision!(channel, hash, released_at, previous \\ nil) do
    ChannelRevision.create!(%{
      channel_id: channel.id,
      revision: hash,
      released_at: released_at,
      previous_channel_revision_id: previous && previous.id
    })
  end

  describe "events_between/2" do
    test "derives added and removed packages from span boundaries" do
      channel = Fixtures.channel!("nixos-unstable")
      from_rev = revision!(channel, "from1aaa", ~U[2026-04-01 10:00:00Z])
      to_rev = revision!(channel, "to2bbbb", ~U[2026-04-15 10:00:00Z], from_rev)

      kept = Fixtures.package!("evt-kept")
      removed = Fixtures.package!("evt-removed")
      added = Fixtures.package!("evt-added")

      Fixtures.apply_package_revision!(from_rev, [{kept, "1.0"}, {removed, "1.0"}])
      Fixtures.apply_package_revision!(to_rev, [{kept, "1.0"}, {added, "1.0"}])
      Fixtures.remove_package!(to_rev, removed)

      events = PackageHistory.events_between(to_rev, from_rev.released_at)
      by_attr = Map.new(events, &{&1.package.attribute, &1.type})

      assert by_attr == %{"evt-added" => :added, "evt-removed" => :removed}
      assert Enum.all?(events, &(&1.channel_revision.id == to_rev.id))
    end

    test "is empty when the package set is unchanged" do
      channel = Fixtures.channel!("nixos-unstable")
      from_rev = revision!(channel, "stable01", ~U[2026-05-01 10:00:00Z])
      to_rev = revision!(channel, "stable02", ~U[2026-05-15 10:00:00Z], from_rev)

      pkg = Fixtures.package!("evt-stable")
      Fixtures.apply_package_revision!(from_rev, [{pkg, "1.0"}])
      Fixtures.apply_package_revision!(to_rev, [{pkg, "2.0"}])

      assert PackageHistory.events_between(to_rev, from_rev.released_at) == []
    end
  end

  describe "events_by_package/2" do
    test "derives added/removed boundaries for a single channel" do
      channel = Fixtures.channel!("evt-chan")
      cr1 = revision!(channel, "ebp1aaa", ~U[2026-04-01 10:00:00Z])
      cr2 = revision!(channel, "ebp2bbb", ~U[2026-04-15 10:00:00Z], cr1)

      pkg = Fixtures.package!("ebp-pkg")
      Fixtures.apply_package_revision!(cr1, [{pkg, "1.0"}])
      Fixtures.apply_package_revision!(cr2, [{pkg, "1.0"}])
      Fixtures.remove_package!(cr2, pkg)

      events = PackageHistory.events_by_package(pkg.id, channel.id)

      assert [%{type: :removed}, %{type: :added}] = events
      assert Enum.all?(events, &(&1.channel_revision.channel.name == "evt-chan"))
    end

    test "merges boundaries across channels when channel_id is nil" do
      unstable = Fixtures.channel!("ebp-unstable")
      stable = Fixtures.channel!("ebp-stable")
      pkg = Fixtures.package!("ebp-multi")

      cr_u = revision!(unstable, "ebpu111", ~U[2026-04-01 10:00:00Z])
      cr_s1 = revision!(stable, "ebps111", ~U[2026-04-05 10:00:00Z])
      cr_s2 = revision!(stable, "ebps222", ~U[2026-04-10 10:00:00Z], cr_s1)

      Fixtures.apply_package_revision!(cr_u, [{pkg, "1.0"}])
      Fixtures.apply_package_revision!(cr_s1, [{pkg, "1.0"}])
      Fixtures.remove_package!(cr_s2, pkg)

      events = PackageHistory.events_by_package(pkg.id, nil)

      types_by_channel =
        Enum.map(events, &{&1.channel_revision.channel.name, &1.type})

      assert {"ebp-unstable", :added} in types_by_channel
      assert {"ebp-stable", :added} in types_by_channel
      assert {"ebp-stable", :removed} in types_by_channel
    end
  end

  describe "version_changes_by_package/2" do
    setup do
      channel = Fixtures.channel!("unstable")
      pkg = Fixtures.package!("test-pkg")

      cr1 = revision!(channel, "aaa1111", ~U[2025-01-01 00:00:00Z])
      cr2 = revision!(channel, "bbb2222", ~U[2025-01-02 00:00:00Z], cr1)
      cr3 = revision!(channel, "ccc3333", ~U[2025-01-03 00:00:00Z], cr2)
      cr4 = revision!(channel, "ddd4444", ~U[2025-01-04 00:00:00Z], cr3)

      # Version changes: 1.0 -> 1.0 (same) -> 1.1 -> 1.1 (same)
      Fixtures.apply_package_revision!(cr1, [{pkg, "1.0"}])
      Fixtures.apply_package_revision!(cr2, [{pkg, "1.0"}])
      Fixtures.apply_package_revision!(cr3, [{pkg, "1.1"}])
      Fixtures.apply_package_revision!(cr4, [{pkg, "1.1"}])

      %{pkg: pkg}
    end

    test "returns only revisions where version changed", %{pkg: pkg} do
      {results, count} = PackageHistory.version_changes_by_package(pkg.id)

      assert count == 2
      assert length(results) == 2

      versions = Enum.map(results, & &1.version)
      assert "1.0" in versions
      assert "1.1" in versions
    end

    test "sorts by released_at desc by default", %{pkg: pkg} do
      {results, _count} = PackageHistory.version_changes_by_package(pkg.id)

      assert [first, second] = results
      assert first.version == "1.1"
      assert second.version == "1.0"
    end

    test "carries the revision that introduced each version", %{pkg: pkg} do
      {results, _} = PackageHistory.version_changes_by_package(pkg.id)
      by_version = Map.new(results, &{&1.version, &1})

      assert by_version["1.0"].revision == "aaa1111"
      assert by_version["1.1"].revision == "ccc3333"
      assert by_version["1.0"].channel_name == "unstable"
    end

    test "filters by channel" do
      unstable_ch = Fixtures.channel!("unstable-multi")
      stable_ch = Fixtures.channel!("stable-multi")
      pkg = Fixtures.package!("multi-channel-pkg")

      cr_u1 = revision!(unstable_ch, "uuu1111", ~U[2025-02-01 00:00:00Z])
      cr_u2 = revision!(unstable_ch, "uuu2222", ~U[2025-02-02 00:00:00Z], cr_u1)
      cr_s1 = revision!(stable_ch, "sss1111", ~U[2025-02-01 00:00:00Z])

      Fixtures.apply_package_revision!(cr_u1, [{pkg, "1.0"}])
      Fixtures.apply_package_revision!(cr_u2, [{pkg, "1.1"}])
      Fixtures.apply_package_revision!(cr_s1, [{pkg, "1.0"}])

      {results, count} =
        PackageHistory.version_changes_by_package(pkg.id, channel_id: unstable_ch.id)

      assert count == 2
      channels = results |> Enum.map(& &1.channel_name) |> Enum.uniq()
      assert channels == ["unstable-multi"]
    end

    test "filters by version substring" do
      ver_channel = Fixtures.channel!("unstable-ver")
      pkg = Fixtures.package!("version-filter-pkg")

      cr1 = revision!(ver_channel, "vvv1111", ~U[2025-03-01 00:00:00Z])
      cr2 = revision!(ver_channel, "vvv2222", ~U[2025-03-02 00:00:00Z], cr1)

      Fixtures.apply_package_revision!(cr1, [{pkg, "1.0.0"}])
      Fixtures.apply_package_revision!(cr2, [{pkg, "2.0.0"}])

      {results, count} = PackageHistory.version_changes_by_package(pkg.id, version: "2.0")

      assert count == 1
      assert hd(results).version == "2.0.0"
    end

    test "paginates with limit and offset" do
      pag_channel = Fixtures.channel!("unstable-pag")
      pkg = Fixtures.package!("paginated-pkg")

      previous =
        Enum.reduce(1..5, nil, fn i, prev ->
          cr =
            revision!(
              pag_channel,
              "pag#{String.pad_leading(to_string(i), 4, "0")}",
              DateTime.add(~U[2025-04-01 00:00:00Z], i, :day),
              prev
            )

          Fixtures.apply_package_revision!(cr, [{pkg, "#{i}.0"}])
          cr
        end)

      assert previous.revision == "pag0005"

      {results, count} = PackageHistory.version_changes_by_package(pkg.id, limit: 2, offset: 0)
      assert count == 5
      assert length(results) == 2

      {results2, count2} = PackageHistory.version_changes_by_package(pkg.id, limit: 2, offset: 2)
      assert count2 == 5
      assert length(results2) == 2

      ids1 = MapSet.new(results, & &1.id)
      ids2 = MapSet.new(results2, & &1.id)
      assert MapSet.disjoint?(ids1, ids2)
    end

    test "supports sorting by version asc" do
      sort_channel = Fixtures.channel!("unstable-sort")
      pkg = Fixtures.package!("sort-pkg")

      cr1 = revision!(sort_channel, "sort1111", ~U[2025-05-01 00:00:00Z])
      cr2 = revision!(sort_channel, "sort2222", ~U[2025-05-02 00:00:00Z], cr1)

      Fixtures.apply_package_revision!(cr1, [{pkg, "beta"}])
      Fixtures.apply_package_revision!(cr2, [{pkg, "alpha"}])

      {results, _} =
        PackageHistory.version_changes_by_package(pkg.id, sort_by: :version, sort_dir: :asc)

      assert [first, second] = results
      assert first.version == "alpha"
      assert second.version == "beta"
    end

    test "detects version changes per channel independently" do
      unstable_ic = Fixtures.channel!("unstable-ic")
      stable_ic = Fixtures.channel!("stable-ic")
      pkg = Fixtures.package!("independent-channels-pkg")

      cr_u1 = revision!(unstable_ic, "ic_u1", ~U[2025-06-01 00:00:00Z])
      cr_u2 = revision!(unstable_ic, "ic_u2", ~U[2025-06-02 00:00:00Z], cr_u1)
      cr_s1 = revision!(stable_ic, "ic_s1", ~U[2025-06-01 00:00:00Z])
      cr_s2 = revision!(stable_ic, "ic_s2", ~U[2025-06-02 00:00:00Z], cr_s1)

      # unstable: 1.0 -> 1.0 (no change)
      Fixtures.apply_package_revision!(cr_u1, [{pkg, "1.0"}])
      Fixtures.apply_package_revision!(cr_u2, [{pkg, "1.0"}])

      # stable: 1.0 -> 2.0 (change)
      Fixtures.apply_package_revision!(cr_s1, [{pkg, "1.0"}])
      Fixtures.apply_package_revision!(cr_s2, [{pkg, "2.0"}])

      {results, count} = PackageHistory.version_changes_by_package(pkg.id)

      assert count == 3

      stable_results = Enum.filter(results, &(&1.channel_name == "stable-ic"))
      assert length(stable_results) == 2

      unstable_results = Enum.filter(results, &(&1.channel_name == "unstable-ic"))
      assert length(unstable_results) == 1
    end

    test "returns empty for package with no spans" do
      pkg = Fixtures.package!("empty-pkg")

      {results, count} = PackageHistory.version_changes_by_package(pkg.id)

      assert results == []
      assert count == 0
    end
  end

  describe "revisions_by_package/3" do
    test "reconstructs versions across channels when channel_id is nil" do
      unstable = Fixtures.channel!("rbp-unstable")
      stable = Fixtures.channel!("rbp-stable")
      pkg = Fixtures.package!("rbp-pkg")

      cr_u = revision!(unstable, "rbpu111", ~U[2026-04-01 10:00:00Z])
      cr_s = revision!(stable, "rbps111", ~U[2026-04-05 10:00:00Z])

      Fixtures.apply_package_revision!(cr_u, [{pkg, "1.0"}])
      Fixtures.apply_package_revision!(cr_s, [{pkg, "2.0"}])

      %{results: results, count: count} = PackageHistory.revisions_by_package(pkg.id, nil)

      assert count == 2

      by_channel =
        Map.new(results, &{&1.channel_revision.channel.name, &1.version})

      assert by_channel == %{"rbp-unstable" => "1.0", "rbp-stable" => "2.0"}
    end
  end
end

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

  # A package at 1.0 then 2.0 in a channel of its own, ready to be removed at a
  # third revision.
  defp versioned_package(name) do
    channel = Fixtures.channel!(name)
    pkg = Fixtures.package!("#{name}-pkg")

    cr1 = revision!(channel, "#{name}1", ~U[2026-04-01 10:00:00Z])
    cr2 = revision!(channel, "#{name}2", ~U[2026-04-02 10:00:00Z], cr1)

    Fixtures.apply_package_revision!(cr1, [{pkg, "1.0"}])
    Fixtures.apply_package_revision!(cr2, [{pkg, "2.0"}])

    %{pkg: pkg, channel: channel, cr2: cr2}
  end

  describe "events_between/2" do
    test "derives added and removed packages from span boundaries" do
      channel = Fixtures.channel!()
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
      channel = Fixtures.channel!()
      from_rev = revision!(channel, "stable01", ~U[2026-05-01 10:00:00Z])
      to_rev = revision!(channel, "stable02", ~U[2026-05-15 10:00:00Z], from_rev)

      pkg = Fixtures.package!("evt-stable")
      Fixtures.apply_package_revision!(from_rev, [{pkg, "1.0"}])
      Fixtures.apply_package_revision!(to_rev, [{pkg, "2.0"}])

      assert PackageHistory.events_between(to_rev, from_rev.released_at) == []
    end
  end

  describe "diff_between/2" do
    test "reports a version change with both endpoints" do
      channel = Fixtures.channel!()
      from_rev = revision!(channel, "dbver001", ~U[2026-04-01 10:00:00Z])
      to_rev = revision!(channel, "dbver002", ~U[2026-04-15 10:00:00Z], from_rev)

      pkg = Fixtures.package!("dbver-pkg")
      Fixtures.apply_package_revision!(from_rev, [{pkg, "1.0"}])
      Fixtures.apply_package_revision!(to_rev, [{pkg, "2.0"}])

      diff = PackageHistory.diff_between(to_rev, from_rev.released_at)

      assert diff.events == []

      assert [%{attribute: "dbver-pkg", old_version: "1.0", new_version: "2.0"}] =
               diff.version_changes
    end

    test "reports an addition with a nil old version" do
      channel = Fixtures.channel!()
      from_rev = revision!(channel, "dbadd001", ~U[2026-04-01 10:00:00Z])
      to_rev = revision!(channel, "dbadd002", ~U[2026-04-15 10:00:00Z], from_rev)

      kept = Fixtures.package!("dbadd-kept")
      added = Fixtures.package!("dbadd-new")
      Fixtures.apply_package_revision!(from_rev, [{kept, "1.0"}])
      Fixtures.apply_package_revision!(to_rev, [{kept, "1.0"}, {added, "3.0"}])

      diff = PackageHistory.diff_between(to_rev, from_rev.released_at)

      assert [%{type: :added, package: %{attribute: "dbadd-new"}}] = diff.events

      assert [%{attribute: "dbadd-new", old_version: nil, new_version: "3.0"}] =
               diff.version_changes
    end

    test "reports a removal with a nil new version" do
      channel = Fixtures.channel!()
      from_rev = revision!(channel, "dbrem001", ~U[2026-04-01 10:00:00Z])
      to_rev = revision!(channel, "dbrem002", ~U[2026-04-15 10:00:00Z], from_rev)

      kept = Fixtures.package!("dbrem-kept")
      gone = Fixtures.package!("dbrem-gone")
      Fixtures.apply_package_revision!(from_rev, [{kept, "1.0"}, {gone, "1.0"}])
      Fixtures.apply_package_revision!(to_rev, [{kept, "1.0"}])
      Fixtures.remove_package!(to_rev, gone)

      diff = PackageHistory.diff_between(to_rev, from_rev.released_at)

      assert [%{type: :removed, package: %{attribute: "dbrem-gone"}}] = diff.events

      assert [%{attribute: "dbrem-gone", old_version: "1.0", new_version: nil}] =
               diff.version_changes
    end

    test "is empty when nothing changed in the window" do
      channel = Fixtures.channel!()
      before_rev = revision!(channel, "dbnop000", ~U[2026-03-01 10:00:00Z])
      from_rev = revision!(channel, "dbnop001", ~U[2026-04-01 10:00:00Z], before_rev)
      to_rev = revision!(channel, "dbnop002", ~U[2026-04-15 10:00:00Z], from_rev)

      pkg = Fixtures.package!("dbnop-pkg")
      Fixtures.apply_package_revision!(before_rev, [{pkg, "1.0"}])
      Fixtures.apply_package_revision!(from_rev, [{pkg, "2.0"}])
      Fixtures.apply_package_revision!(to_rev, [{pkg, "2.0"}])

      diff = PackageHistory.diff_between(to_rev, from_rev.released_at)

      assert diff.events == []
      assert diff.version_changes == []
    end

    test "ignores a package that changes and changes back inside the window" do
      channel = Fixtures.channel!()
      from_rev = revision!(channel, "dbrtp001", ~U[2026-04-01 10:00:00Z])
      mid_rev = revision!(channel, "dbrtp002", ~U[2026-04-08 10:00:00Z], from_rev)
      to_rev = revision!(channel, "dbrtp003", ~U[2026-04-15 10:00:00Z], mid_rev)

      pkg = Fixtures.package!("dbrtp-pkg")
      Fixtures.apply_package_revision!(from_rev, [{pkg, "1.0"}])
      Fixtures.apply_package_revision!(mid_rev, [{pkg, "2.0"}])
      Fixtures.apply_package_revision!(to_rev, [{pkg, "1.0"}])

      diff = PackageHistory.diff_between(to_rev, from_rev.released_at)

      assert diff.events == []
      assert diff.version_changes == []
    end

    test "nets out intermediate revisions for a non-adjacent pair" do
      channel = Fixtures.channel!()
      from_rev = revision!(channel, "dbnet001", ~U[2026-04-01 10:00:00Z])
      mid_rev = revision!(channel, "dbnet002", ~U[2026-04-08 10:00:00Z], from_rev)
      to_rev = revision!(channel, "dbnet003", ~U[2026-04-15 10:00:00Z], mid_rev)

      pkg = Fixtures.package!("dbnet-pkg")
      short_lived = Fixtures.package!("dbnet-transient")

      Fixtures.apply_package_revision!(from_rev, [{pkg, "1.0"}])
      Fixtures.apply_package_revision!(mid_rev, [{pkg, "2.0"}, {short_lived, "0.1"}])
      Fixtures.apply_package_revision!(to_rev, [{pkg, "3.0"}])
      Fixtures.remove_package!(to_rev, short_lived)

      diff = PackageHistory.diff_between(to_rev, from_rev.released_at)

      assert diff.events == []

      assert [%{attribute: "dbnet-pkg", old_version: "1.0", new_version: "3.0"}] =
               diff.version_changes
    end

    test "sorts version changes by attribute" do
      channel = Fixtures.channel!()
      from_rev = revision!(channel, "dbsrt001", ~U[2026-04-01 10:00:00Z])
      to_rev = revision!(channel, "dbsrt002", ~U[2026-04-15 10:00:00Z], from_rev)

      zed = Fixtures.package!("dbsrt-zed")
      alpha = Fixtures.package!("dbsrt-alpha")
      Fixtures.apply_package_revision!(from_rev, [{zed, "1.0"}, {alpha, "1.0"}])
      Fixtures.apply_package_revision!(to_rev, [{zed, "2.0"}, {alpha, "2.0"}])

      diff = PackageHistory.diff_between(to_rev, from_rev.released_at)

      assert Enum.map(diff.version_changes, & &1.attribute) == ["dbsrt-alpha", "dbsrt-zed"]
    end

    test "ignores changes outside the window" do
      channel = Fixtures.channel!()
      old_rev = revision!(channel, "dbout001", ~U[2026-02-01 10:00:00Z])
      from_rev = revision!(channel, "dbout002", ~U[2026-04-01 10:00:00Z], old_rev)
      to_rev = revision!(channel, "dbout003", ~U[2026-04-15 10:00:00Z], from_rev)
      later_rev = revision!(channel, "dbout004", ~U[2026-05-01 10:00:00Z], to_rev)

      early = Fixtures.package!("dbout-early")
      late = Fixtures.package!("dbout-late")
      changed = Fixtures.package!("dbout-changed")

      Fixtures.apply_package_revision!(old_rev, [{early, "1.0"}, {changed, "1.0"}])
      Fixtures.apply_package_revision!(from_rev, [{early, "2.0"}, {changed, "1.0"}])
      Fixtures.apply_package_revision!(to_rev, [{early, "2.0"}, {changed, "2.0"}])

      Fixtures.apply_package_revision!(later_rev, [
        {early, "2.0"},
        {changed, "2.0"},
        {late, "1.0"}
      ])

      diff = PackageHistory.diff_between(to_rev, from_rev.released_at)

      assert diff.events == []
      assert Enum.map(diff.version_changes, & &1.attribute) == ["dbout-changed"]
    end
  end

  describe "terminal_removal/2" do
    test "derives the removal boundary from the channel's closed latest span" do
      channel = Fixtures.channel!("evt-chan")
      cr1 = revision!(channel, "ebp1aaa", ~U[2026-04-01 10:00:00Z])
      cr2 = revision!(channel, "ebp2bbb", ~U[2026-04-15 10:00:00Z], cr1)

      pkg = Fixtures.package!("ebp-pkg")
      Fixtures.apply_package_revision!(cr1, [{pkg, "1.0"}])
      Fixtures.apply_package_revision!(cr2, [{pkg, "1.0"}])
      Fixtures.remove_package!(cr2, pkg)

      assert %PackageHistory.Removal{} =
               removal = PackageHistory.terminal_removal(pkg.id, channel.id)

      assert removal.revision == "ebp2bbb"
      assert removal.channel_name == "evt-chan"
      assert removal.released_at == ~U[2026-04-15 10:00:00Z]
      assert removal.version == "1.0"
    end

    test "is nil for a package removed and re-added" do
      channel = Fixtures.channel!("evt-readd")
      cr1 = revision!(channel, "erd1aaa", ~U[2026-04-01 10:00:00Z])
      cr2 = revision!(channel, "erd2bbb", ~U[2026-04-15 10:00:00Z], cr1)
      cr3 = revision!(channel, "erd3ccc", ~U[2026-04-20 10:00:00Z], cr2)

      pkg = Fixtures.package!("erd-pkg")
      Fixtures.apply_package_revision!(cr1, [{pkg, "1.0"}])
      Fixtures.remove_package!(cr2, pkg)
      Fixtures.apply_package_revision!(cr3, [{pkg, "2.0"}])

      assert PackageHistory.terminal_removal(pkg.id, channel.id) == nil
    end

    test "is nil for a package still present in the channel" do
      channel = Fixtures.channel!("ebp-open")
      cr = revision!(channel, "ebpo111", ~U[2026-04-01 10:00:00Z])

      pkg = Fixtures.package!("ebp-open-pkg")
      Fixtures.apply_package_revision!(cr, [{pkg, "1.0"}])

      assert PackageHistory.terminal_removal(pkg.id, channel.id) == nil
    end

    test "is nil for a package that was never in the channel" do
      channel = Fixtures.channel!("ebp-elsewhere")
      other = Fixtures.channel!("ebp-elsewhere-other")
      cr = revision!(other, "ebpe111", ~U[2026-04-01 10:00:00Z])

      pkg = Fixtures.package!("ebp-elsewhere-pkg")
      Fixtures.apply_package_revision!(cr, [{pkg, "1.0"}])

      assert PackageHistory.terminal_removal(pkg.id, channel.id) == nil
    end

    test "describes only the channel asked about" do
      unstable = Fixtures.channel!("ebp-unstable")
      stable = Fixtures.channel!("ebp-stable")
      pkg = Fixtures.package!("ebp-multi")

      cr_u = revision!(unstable, "ebpu111", ~U[2026-04-01 10:00:00Z])
      cr_s1 = revision!(stable, "ebps111", ~U[2026-04-05 10:00:00Z])
      cr_s2 = revision!(stable, "ebps222", ~U[2026-04-10 10:00:00Z], cr_s1)

      Fixtures.apply_package_revision!(cr_u, [{pkg, "1.0"}])
      Fixtures.apply_package_revision!(cr_s1, [{pkg, "1.0"}])
      Fixtures.remove_package!(cr_s2, pkg)

      assert PackageHistory.terminal_removal(pkg.id, unstable.id) == nil
      assert %{channel_name: "ebp-stable"} = PackageHistory.terminal_removal(pkg.id, stable.id)
    end
  end

  describe "absent_from_live_channels?/1" do
    test "is false while any live channel holds the package open" do
      unstable = Fixtures.channel!("afl-unstable")
      stable = Fixtures.channel!("afl-stable")
      pkg = Fixtures.package!("afl-pkg")

      cr_u = revision!(unstable, "afl_u11", ~U[2026-04-01 10:00:00Z])
      cr_u2 = revision!(unstable, "afl_u22", ~U[2026-04-02 10:00:00Z], cr_u)
      cr_s = revision!(stable, "afl_s11", ~U[2026-04-01 10:00:00Z])

      Fixtures.apply_package_revision!(cr_u, [{pkg, "1.0"}])
      Fixtures.remove_package!(cr_u2, pkg)
      Fixtures.apply_package_revision!(cr_s, [{pkg, "1.0"}])

      refute PackageHistory.absent_from_live_channels?(pkg.id)
    end

    test "is true once every channel's span is closed" do
      channel = Fixtures.channel!("afl-closed")
      pkg = Fixtures.package!("afl-closed-pkg")

      cr1 = revision!(channel, "aflc111", ~U[2026-04-01 10:00:00Z])
      cr2 = revision!(channel, "aflc222", ~U[2026-04-02 10:00:00Z], cr1)

      Fixtures.apply_package_revision!(cr1, [{pkg, "1.0"}])
      Fixtures.remove_package!(cr2, pkg)

      assert PackageHistory.absent_from_live_channels?(pkg.id)
    end

    test "ignores the never-closing spans a retired channel leaves behind" do
      retired = Fixtures.channel!("afl-retired")
      Tracker.Nixpkgs.Channel.update_status!(retired, %{status: :retired})

      pkg = Fixtures.package!("afl-retired-pkg")
      cr = revision!(retired, "aflr111", ~U[2026-04-01 10:00:00Z])
      Fixtures.apply_package_revision!(cr, [{pkg, "1.0"}])

      assert PackageHistory.absent_from_live_channels?(pkg.id)
    end

    test "counts a pre-release channel as live" do
      pre = Fixtures.channel!("afl-pre")
      Tracker.Nixpkgs.Channel.update_status!(pre, %{status: :pre_release})

      pkg = Fixtures.package!("afl-pre-pkg")
      cr = revision!(pre, "aflp111", ~U[2026-04-01 10:00:00Z])
      Fixtures.apply_package_revision!(cr, [{pkg, "1.0"}])

      refute PackageHistory.absent_from_live_channels?(pkg.id)
    end

    test "is true for a package with no spans at all" do
      assert PackageHistory.absent_from_live_channels?(Fixtures.package!("afl-nospan").id)
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

    test "flags the first appearance as an addition", %{pkg: pkg} do
      {results, _} = PackageHistory.version_changes_by_package(pkg.id)

      assert Map.new(results, &{&1.version, &1.added?}) == %{"1.0" => true, "1.1" => false}
    end

    test "flags a re-addition after a removal" do
      channel = Fixtures.channel!("readd-channel")
      pkg = Fixtures.package!("readd-pkg")

      cr1 = revision!(channel, "read111", ~U[2025-07-01 00:00:00Z])
      cr2 = revision!(channel, "read222", ~U[2025-07-02 00:00:00Z], cr1)
      cr3 = revision!(channel, "read333", ~U[2025-07-03 00:00:00Z], cr2)

      Fixtures.apply_package_revision!(cr1, [{pkg, "1.0"}])
      Fixtures.remove_package!(cr2, pkg)
      Fixtures.apply_package_revision!(cr3, [{pkg, "2.0"}])

      {results, _} = PackageHistory.version_changes_by_package(pkg.id)

      assert Map.new(results, &{&1.version, &1.added?}) == %{"1.0" => true, "2.0" => true}
    end

    test "carries the position recorded on each span" do
      channel = Fixtures.channel!("vcp-channel")
      pkg = Fixtures.package!("vcp-pkg")

      cr1 = revision!(channel, "vcp1111", ~U[2025-05-01 00:00:00Z])
      cr2 = revision!(channel, "vcp2222", ~U[2025-05-02 00:00:00Z], cr1)

      Fixtures.apply_package_revision!(cr1, [
        {pkg, %{version: "1.0", position: "pkgs/old/default.nix:10"}}
      ])

      Fixtures.apply_package_revision!(cr2, [
        {pkg, %{version: "2.0", position: "pkgs/new/default.nix:20"}}
      ])

      {results, _} = PackageHistory.version_changes_by_package(pkg.id)

      assert Map.new(results, &{&1.version, &1.position}) == %{
               "1.0" => "pkgs/old/default.nix:10",
               "2.0" => "pkgs/new/default.nix:20"
             }
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

    test "omits removal rows unless asked for them" do
      %{pkg: pkg, channel: channel} = versioned_package("vcr-plain")
      cr = revision!(channel, "vcr_p33", ~U[2026-04-03 10:00:00Z])
      Fixtures.remove_package!(cr, pkg)

      {results, count} = PackageHistory.version_changes_by_package(pkg.id)

      assert count == 2
      assert Enum.all?(results, &match?(%PackageHistory.VersionChange{}, &1))
    end

    test "injects a removal row carrying the closing span's version" do
      %{pkg: pkg, channel: channel} = versioned_package("vcr-row")
      cr = revision!(channel, "vcr_r33", ~U[2026-04-03 10:00:00Z])
      Fixtures.remove_package!(cr, pkg)

      {results, count} = PackageHistory.version_changes_by_package(pkg.id, removals?: true)

      assert count == 3

      assert [%PackageHistory.Removal{} = removal | _] = results
      assert removal.version == "2.0"
      assert removal.channel_name == "vcr-row"
      assert removal.revision == "vcr_r33"
      assert removal.released_at == ~U[2026-04-03 10:00:00Z]
    end

    test "keeps a removal that ended a version the filter matches" do
      %{pkg: pkg, channel: channel} = versioned_package("vcr-filter")
      cr = revision!(channel, "vcr_f33", ~U[2026-04-03 10:00:00Z])
      Fixtures.remove_package!(cr, pkg)

      {results, _} =
        PackageHistory.version_changes_by_package(pkg.id, removals?: true, version: "2.0")

      assert [%PackageHistory.Removal{}, %PackageHistory.VersionChange{version: "2.0"}] = results

      {results, _} =
        PackageHistory.version_changes_by_package(pkg.id, removals?: true, version: "1.0")

      assert [%PackageHistory.VersionChange{version: "1.0"}] = results
    end
  end

  describe "versions_at_revisions/2" do
    test "maps package versions per revision across channels" do
      chan_a = Fixtures.channel!()
      chan_b = Fixtures.channel!()
      r1 = revision!(chan_a, "aaaa0001", ~U[2026-06-01 10:00:00Z])
      r2 = revision!(chan_a, "aaaa0002", ~U[2026-06-15 10:00:00Z], r1)
      rb = revision!(chan_b, "bbbb0001", ~U[2026-06-10 10:00:00Z])

      pkg = Fixtures.package!()
      other = Fixtures.package!()

      Fixtures.apply_package_revision!(r1, [{pkg, "1.0"}, {other, "5.0"}])
      Fixtures.apply_package_revision!(r2, [{pkg, "2.0"}])
      Fixtures.apply_package_revision!(rb, [{pkg, "1.5"}])

      versions = PackageHistory.versions_at_revisions([r1.id, r2.id, rb.id], [pkg.id])

      assert versions == %{
               {pkg.id, r1.id} => "1.0",
               {pkg.id, r2.id} => "2.0",
               {pkg.id, rb.id} => "1.5"
             }
    end

    test "omits revisions where the package has no covering span" do
      chan = Fixtures.channel!()
      before_pkg = revision!(chan, "aaaa0001", ~U[2026-06-01 10:00:00Z])
      with_pkg = revision!(chan, "aaaa0002", ~U[2026-06-15 10:00:00Z], before_pkg)

      pkg = Fixtures.package!()
      Fixtures.apply_package_revision!(with_pkg, [{pkg, "1.0"}])

      versions = PackageHistory.versions_at_revisions([before_pkg.id, with_pkg.id], [pkg.id])

      assert versions == %{{pkg.id, with_pkg.id} => "1.0"}
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

    test "carries the covering span's position at each revision" do
      channel = Fixtures.channel!("rbp-pos")
      pkg = Fixtures.package!("rbp-pos-pkg")

      cr1 = revision!(channel, "rbpp111", ~U[2026-05-01 10:00:00Z])
      cr2 = revision!(channel, "rbpp222", ~U[2026-05-02 10:00:00Z], cr1)

      Fixtures.apply_package_revision!(cr1, [
        {pkg, %{version: "1.0", position: "pkgs/old/default.nix:10"}}
      ])

      Fixtures.apply_package_revision!(cr2, [
        {pkg, %{version: "2.0", position: "pkgs/new/default.nix:20"}}
      ])

      %{results: results} = PackageHistory.revisions_by_package(pkg.id, channel.id)

      assert Map.new(results, &{&1.channel_revision.revision, &1.position}) == %{
               "rbpp111" => "pkgs/old/default.nix:10",
               "rbpp222" => "pkgs/new/default.nix:20"
             }
    end

    test "flags the revision the package appeared at" do
      channel = Fixtures.channel!("rbp-added")
      pkg = Fixtures.package!("rbp-added-pkg")

      cr1 = revision!(channel, "rbpa111", ~U[2026-06-01 10:00:00Z])
      cr2 = revision!(channel, "rbpa222", ~U[2026-06-02 10:00:00Z], cr1)
      cr3 = revision!(channel, "rbpa333", ~U[2026-06-03 10:00:00Z], cr2)

      Fixtures.apply_package_revision!(cr2, [{pkg, "1.0"}])
      Fixtures.apply_package_revision!(cr3, [{pkg, "1.0"}])

      %{results: results} = PackageHistory.revisions_by_package(pkg.id, channel.id)

      assert Map.new(results, &{&1.channel_revision.revision, &1.added?}) == %{
               "rbpa222" => true,
               "rbpa333" => false
             }
    end

    test "emits a removal row at the revision the package left" do
      %{pkg: pkg, channel: channel, cr2: cr2} = versioned_package("rbp-gone")
      cr3 = revision!(channel, "rbpg333", ~U[2026-04-03 10:00:00Z], cr2)
      Fixtures.remove_package!(cr3, pkg)

      %{results: results, count: count} = PackageHistory.revisions_by_package(pkg.id, channel.id)

      assert count == 3

      assert [%PackageHistory.Removal{} = removal | _] = results
      assert removal.version == "2.0"
      assert removal.channel_name == "rbp-gone"
      assert removal.revision == "rbpg333"
      assert removal.released_at == ~U[2026-04-03 10:00:00Z]
    end

    test "leaves the revisions between a removal and a re-addition unrowed" do
      channel = Fixtures.channel!("rbp-gap")
      pkg = Fixtures.package!("rbp-gap-pkg")

      cr1 = revision!(channel, "rbpgap1", ~U[2026-04-01 10:00:00Z])
      cr2 = revision!(channel, "rbpgap2", ~U[2026-04-02 10:00:00Z], cr1)
      cr3 = revision!(channel, "rbpgap3", ~U[2026-04-03 10:00:00Z], cr2)
      cr4 = revision!(channel, "rbpgap4", ~U[2026-04-04 10:00:00Z], cr3)

      Fixtures.apply_package_revision!(cr1, [{pkg, "1.0"}])
      Fixtures.remove_package!(cr2, pkg)
      Fixtures.apply_package_revision!(cr4, [{pkg, "2.0"}])

      %{results: results} =
        PackageHistory.revisions_by_package(pkg.id, channel.id, sort_dir: :asc)

      assert [
               %{version: "1.0", added?: true},
               %PackageHistory.Removal{revision: "rbpgap2"},
               %{version: "2.0", added?: true}
             ] = results
    end
  end

  describe "metadata_at/3" do
    test "resolves the span valid at a point in time, not the open one" do
      channel = Fixtures.channel!("meta-at")
      pkg = Fixtures.package!("meta-at-pkg")

      cr1 = revision!(channel, "mat1111", ~U[2026-07-01 10:00:00Z])
      cr2 = revision!(channel, "mat2222", ~U[2026-07-02 10:00:00Z], cr1)

      Fixtures.apply_package_revision!(cr1, [
        {pkg, %{version: "1.0", description: "old description"}}
      ])

      Fixtures.apply_package_revision!(cr2, [
        {pkg, %{version: "2.0", description: "new description"}}
      ])

      pinned = PackageHistory.metadata_at(channel.id, cr1.released_at, [pkg.id])
      current = PackageHistory.current_metadata(channel.id, [pkg.id])

      assert pinned[pkg.id].description == "old description"
      assert current[pkg.id].description == "new description"
    end

    test "is empty for a package with no span at that point" do
      channel = Fixtures.channel!("meta-at-empty")
      pkg = Fixtures.package!("meta-at-empty-pkg")

      cr1 = revision!(channel, "mae1111", ~U[2026-07-01 10:00:00Z])
      cr2 = revision!(channel, "mae2222", ~U[2026-07-02 10:00:00Z], cr1)

      Fixtures.apply_package_revision!(cr2, [{pkg, "1.0"}])

      assert PackageHistory.metadata_at(channel.id, cr1.released_at, [pkg.id]) == %{}
    end
  end
end

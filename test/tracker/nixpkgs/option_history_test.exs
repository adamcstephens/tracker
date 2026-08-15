defmodule Tracker.Nixpkgs.OptionHistoryTest do
  use Tracker.DataCase, async: true

  alias Tracker.Fixtures
  alias Tracker.Nixpkgs.{ChannelRevision, OptionHistory}

  defp revision!(channel, hash, released_at, previous \\ nil) do
    ChannelRevision.create!(%{
      channel_id: channel.id,
      revision: hash,
      released_at: released_at,
      previous_channel_revision_id: previous && previous.id
    })
  end

  describe "events_between/2" do
    test "derives added and removed options from span boundaries" do
      channel = Fixtures.channel!("nixos-unstable")
      from_rev = revision!(channel, "from1aaa", ~U[2026-04-01 10:00:00Z])
      to_rev = revision!(channel, "to2bbbb", ~U[2026-04-15 10:00:00Z], from_rev)

      kept = Fixtures.option!("services.kept")
      removed = Fixtures.option!("services.removed")
      added = Fixtures.option!("services.added")

      Fixtures.apply_option_revision!(from_rev, [
        {kept, %{type: "bool"}},
        {removed, %{type: "bool"}}
      ])

      Fixtures.apply_option_revision!(to_rev, [{kept, %{type: "bool"}}, {added, %{type: "bool"}}])
      Fixtures.remove_option!(to_rev, removed)

      events = OptionHistory.events_between(to_rev, from_rev.released_at)
      by_name = Map.new(events, &{&1.option.name, &1.type})

      assert by_name == %{"services.added" => :added, "services.removed" => :removed}
      assert Enum.all?(events, &(&1.channel_revision.id == to_rev.id))
    end

    test "is empty when the option set is unchanged" do
      channel = Fixtures.channel!("nixos-unstable")
      from_rev = revision!(channel, "stable01", ~U[2026-05-01 10:00:00Z])
      to_rev = revision!(channel, "stable02", ~U[2026-05-15 10:00:00Z], from_rev)

      opt = Fixtures.option!("services.stable")
      Fixtures.apply_option_revision!(from_rev, [{opt, %{type: "bool"}}])
      Fixtures.apply_option_revision!(to_rev, [{opt, %{type: "str"}}])

      assert OptionHistory.events_between(to_rev, from_rev.released_at) == []
    end
  end

  describe "metadata_diff/2" do
    test "emits one struct per changed field for options in both revisions" do
      channel = Fixtures.channel!("nixos-unstable")
      from_rev = revision!(channel, "metaaaaa", ~U[2026-04-01 10:00:00Z])
      to_rev = revision!(channel, "metbbbbb", ~U[2026-04-15 10:00:00Z], from_rev)

      changed = Fixtures.option!("services.changed")
      gone = Fixtures.option!("services.gone")
      fresh = Fixtures.option!("services.fresh")

      Fixtures.apply_option_revision!(from_rev, [
        {changed, %{type: "bool", description: "old", read_only: false}},
        {gone, %{type: "str"}}
      ])

      Fixtures.apply_option_revision!(to_rev, [
        {changed, %{type: "str", description: "new", read_only: true}},
        {fresh, %{type: "str"}}
      ])

      Fixtures.remove_option!(to_rev, gone)

      diffs = OptionHistory.metadata_diff(from_rev, to_rev)
      fields = Enum.map(diffs, & &1.field) |> Enum.sort()

      assert fields == [:description, :read_only, :type]
      assert Enum.all?(diffs, &(&1.option_name == "services.changed"))

      type_diff = Enum.find(diffs, &(&1.field == :type))
      assert type_diff.old == "bool"
      assert type_diff.new == "str"
    end

    test "ignores options present in only one revision" do
      channel = Fixtures.channel!("nixos-unstable")
      from_rev = revision!(channel, "onlyaaaa", ~U[2026-04-01 10:00:00Z])
      to_rev = revision!(channel, "onlybbbb", ~U[2026-04-15 10:00:00Z], from_rev)

      opt = Fixtures.option!("services.only")
      Fixtures.apply_option_revision!(to_rev, [{opt, %{type: "bool"}}])

      assert OptionHistory.metadata_diff(from_rev, to_rev) == []
    end
  end

  describe "diff_between/2" do
    test "is empty when nothing changed in the window" do
      channel = Fixtures.channel!()
      before_rev = revision!(channel, "odnop000", ~U[2026-03-01 10:00:00Z])
      from_rev = revision!(channel, "odnop001", ~U[2026-04-01 10:00:00Z], before_rev)
      to_rev = revision!(channel, "odnop002", ~U[2026-04-15 10:00:00Z], from_rev)

      opt = Fixtures.option!("services.odnop")
      Fixtures.apply_option_revision!(before_rev, [{opt, %{type: "bool"}}])
      Fixtures.apply_option_revision!(from_rev, [{opt, %{type: "str"}}])
      Fixtures.apply_option_revision!(to_rev, [{opt, %{type: "str"}}])

      diff = OptionHistory.diff_between(to_rev, from_rev.released_at)

      assert diff.events == []
      assert diff.metadata_changes == []
    end

    test "ignores an option that changes and changes back inside the window" do
      channel = Fixtures.channel!()
      from_rev = revision!(channel, "odrtp001", ~U[2026-04-01 10:00:00Z])
      mid_rev = revision!(channel, "odrtp002", ~U[2026-04-08 10:00:00Z], from_rev)
      to_rev = revision!(channel, "odrtp003", ~U[2026-04-15 10:00:00Z], mid_rev)

      opt = Fixtures.option!("services.odrtp")
      Fixtures.apply_option_revision!(from_rev, [{opt, %{type: "bool"}}])
      Fixtures.apply_option_revision!(mid_rev, [{opt, %{type: "str"}}])
      Fixtures.apply_option_revision!(to_rev, [{opt, %{type: "bool"}}])

      diff = OptionHistory.diff_between(to_rev, from_rev.released_at)

      assert diff.events == []
      assert diff.metadata_changes == []
    end

    test "nets out intermediate revisions for a non-adjacent pair" do
      channel = Fixtures.channel!()
      from_rev = revision!(channel, "odnet001", ~U[2026-04-01 10:00:00Z])
      mid_rev = revision!(channel, "odnet002", ~U[2026-04-08 10:00:00Z], from_rev)
      to_rev = revision!(channel, "odnet003", ~U[2026-04-15 10:00:00Z], mid_rev)

      opt = Fixtures.option!("services.odnet")
      transient = Fixtures.option!("services.odnet-transient")

      Fixtures.apply_option_revision!(from_rev, [{opt, %{type: "bool"}}])

      Fixtures.apply_option_revision!(mid_rev, [
        {opt, %{type: "str"}},
        {transient, %{type: "int"}}
      ])

      Fixtures.apply_option_revision!(to_rev, [{opt, %{type: "path"}}])
      Fixtures.remove_option!(to_rev, transient)

      diff = OptionHistory.diff_between(to_rev, from_rev.released_at)

      assert diff.events == []

      assert [%{option_name: "services.odnet", field: :type, old: "bool", new: "path"}] =
               diff.metadata_changes
    end

    test "reports no metadata change when only an untracked payload field moved" do
      channel = Fixtures.channel!()
      from_rev = revision!(channel, "odunt001", ~U[2026-04-01 10:00:00Z])
      to_rev = revision!(channel, "odunt002", ~U[2026-04-15 10:00:00Z], from_rev)

      opt = Fixtures.option!("services.odunt")
      Fixtures.apply_option_revision!(from_rev, [{opt, %{type: "bool", loc: ["a", "b"]}}])
      Fixtures.apply_option_revision!(to_rev, [{opt, %{type: "bool", loc: ["a", "c"]}}])

      diff = OptionHistory.diff_between(to_rev, from_rev.released_at)

      assert diff.events == []
      assert diff.metadata_changes == []
    end

    test "sorts events by option name" do
      channel = Fixtures.channel!()
      from_rev = revision!(channel, "odsrt001", ~U[2026-04-01 10:00:00Z])
      to_rev = revision!(channel, "odsrt002", ~U[2026-04-15 10:00:00Z], from_rev)

      zed = Fixtures.option!("services.zed")
      alpha = Fixtures.option!("services.alpha")
      Fixtures.apply_option_revision!(to_rev, [{zed, %{type: "bool"}}, {alpha, %{type: "bool"}}])

      diff = OptionHistory.diff_between(to_rev, from_rev.released_at)

      assert Enum.map(diff.events, & &1.option.name) == ["services.alpha", "services.zed"]
    end

    test "ignores changes outside the window" do
      channel = Fixtures.channel!()
      old_rev = revision!(channel, "odout001", ~U[2026-02-01 10:00:00Z])
      from_rev = revision!(channel, "odout002", ~U[2026-04-01 10:00:00Z], old_rev)
      to_rev = revision!(channel, "odout003", ~U[2026-04-15 10:00:00Z], from_rev)
      later_rev = revision!(channel, "odout004", ~U[2026-05-01 10:00:00Z], to_rev)

      early = Fixtures.option!("services.odout-early")
      late = Fixtures.option!("services.odout-late")
      changed = Fixtures.option!("services.odout-changed")

      Fixtures.apply_option_revision!(old_rev, [
        {early, %{type: "bool"}},
        {changed, %{type: "bool"}}
      ])

      Fixtures.apply_option_revision!(from_rev, [
        {early, %{type: "str"}},
        {changed, %{type: "bool"}}
      ])

      Fixtures.apply_option_revision!(to_rev, [
        {early, %{type: "str"}},
        {changed, %{type: "str"}}
      ])

      Fixtures.apply_option_revision!(later_rev, [
        {early, %{type: "str"}},
        {changed, %{type: "str"}},
        {late, %{type: "int"}}
      ])

      diff = OptionHistory.diff_between(to_rev, from_rev.released_at)

      assert diff.events == []
      assert Enum.map(diff.metadata_changes, & &1.option_name) == ["services.odout-changed"]
    end
  end

  describe "current_metadata/1" do
    test "returns the open span per option" do
      channel = Fixtures.channel!("nixos-unstable")
      r1 = revision!(channel, "curr0001", ~U[2026-04-01 10:00:00Z])
      r2 = revision!(channel, "curr0002", ~U[2026-04-15 10:00:00Z], r1)

      opt = Fixtures.option!("services.current")
      Fixtures.apply_option_revision!(r1, [{opt, %{type: "bool", description: "v1"}}])
      Fixtures.apply_option_revision!(r2, [{opt, %{type: "str", description: "v2"}}])

      current = OptionHistory.current_metadata([opt.id])

      assert current[opt.id].type == "str"
      assert current[opt.id].description == "v2"
    end

    test "is empty for no option ids" do
      assert OptionHistory.current_metadata([]) == %{}
    end
  end
end

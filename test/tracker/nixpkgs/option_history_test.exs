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

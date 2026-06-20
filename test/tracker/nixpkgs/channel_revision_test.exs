defmodule Tracker.Nixpkgs.ChannelRevisionTest do
  use Tracker.DataCase, async: true

  alias Tracker.Fixtures
  alias Tracker.Nixpkgs.{Channel, ChannelRevision}

  defp create_channel!(name) do
    Channel.create!(%{
      name: name,
      display_name: name,
      status: :active,
      is_stable: false
    })
  end

  describe "create/1" do
    test "creates a channel revision linked to a channel" do
      channel = create_channel!("nixos-unstable")

      {:ok, rev} =
        ChannelRevision.create(%{
          channel_id: channel.id,
          revision: "abc123",
          released_at: ~U[2026-04-01 10:00:00Z]
        })

      assert rev.channel_id == channel.id
      assert rev.revision == "abc123"
    end

    test "upserts on channel_id + revision" do
      channel = create_channel!("nixos-unstable")

      {:ok, r1} =
        ChannelRevision.create(%{
          channel_id: channel.id,
          revision: "abc123",
          released_at: ~U[2026-04-01 10:00:00Z]
        })

      {:ok, r2} =
        ChannelRevision.create(%{
          channel_id: channel.id,
          revision: "abc123",
          released_at: ~U[2026-04-02 10:00:00Z]
        })

      assert r1.id == r2.id
      assert r2.released_at == ~U[2026-04-02 10:00:00Z]
    end
  end

  describe "by_channel/1" do
    test "returns revisions for a given channel" do
      ch1 = create_channel!("nixos-unstable")
      ch2 = create_channel!("nixos-24.11")

      ChannelRevision.create!(%{
        channel_id: ch1.id,
        revision: "abc1",
        released_at: ~U[2026-04-01 10:00:00Z]
      })

      ChannelRevision.create!(%{
        channel_id: ch2.id,
        revision: "abc2",
        released_at: ~U[2026-04-01 10:00:00Z]
      })

      revs = ChannelRevision.by_channel!(ch1.id)
      assert length(revs) == 1
      assert hd(revs).revision == "abc1"
    end
  end

  describe "find_by_channel_hash/2" do
    test "finds by channel_id and revision prefix" do
      channel = create_channel!("nixos-unstable")

      ChannelRevision.create!(%{
        channel_id: channel.id,
        revision: "abc123def456",
        released_at: ~U[2026-04-01 10:00:00Z]
      })

      {:ok, rev} = ChannelRevision.find_by_channel_hash(channel.id, "abc123")
      assert rev.revision == "abc123def456"
    end
  end

  describe "version_diff/2" do
    setup do
      channel = create_channel!("nixos-unstable")

      from_rev =
        ChannelRevision.create!(%{
          channel_id: channel.id,
          revision: "from1aaa",
          released_at: ~U[2026-04-01 10:00:00Z]
        })

      to_rev =
        ChannelRevision.create!(%{
          channel_id: channel.id,
          revision: "to2bbb",
          released_at: ~U[2026-04-15 10:00:00Z],
          previous_channel_revision_id: from_rev.id
        })

      changed = Fixtures.package!("diff-changed")
      removed = Fixtures.package!("diff-removed")
      added = Fixtures.package!("diff-added")

      Fixtures.apply_package_revision!(from_rev, [{changed, "1.0.0"}, {removed, "9.0"}])
      Fixtures.apply_package_revision!(to_rev, [{changed, "1.1.0"}, {added, "2.0"}])
      Fixtures.remove_package!(to_rev, removed)

      %{from_rev: from_rev, to_rev: to_rev}
    end

    test "reconstructs version changes (including added/removed) from spans", %{
      from_rev: from_rev,
      to_rev: to_rev
    } do
      diff = ChannelRevision.version_diff(from_rev, to_rev)
      by_attr = Map.new(diff, &{&1.attribute, &1})

      assert map_size(by_attr) == 3
      assert by_attr["diff-changed"].old_version == "1.0.0"
      assert by_attr["diff-changed"].new_version == "1.1.0"
      assert by_attr["diff-added"].old_version == nil
      assert by_attr["diff-added"].new_version == "2.0"
      assert by_attr["diff-removed"].old_version == "9.0"
      assert by_attr["diff-removed"].new_version == nil
    end

    test "omits packages whose version is unchanged", %{from_rev: from_rev, to_rev: to_rev} do
      diff = ChannelRevision.version_diff(from_rev, to_rev)
      refute Enum.any?(diff, &(&1.old_version == &1.new_version))
    end
  end
end

defmodule Tracker.Nixpkgs.ChannelRevisionTest do
  use Tracker.DataCase, async: true

  alias Tracker.Nixpkgs.{Channel, ChannelRevision}

  defp create_channel!(name) do
    Channel.create!(%{
      name: name,
      display_name: name,
      branch: name,
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
end

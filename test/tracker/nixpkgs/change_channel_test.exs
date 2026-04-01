defmodule Tracker.Nixpkgs.ChangeChannelTest do
  use Tracker.DataCase, async: true

  alias Tracker.Nixpkgs.Change
  alias Tracker.Nixpkgs.ChangeChannel
  alias Tracker.Nixpkgs.ChannelRevision

  defp create_change!(attrs \\ %{}) do
    defaults = %{
      number: System.unique_integer([:positive]),
      title: "test PR",
      state: :merged,
      author: "alice",
      url: "https://github.com/NixOS/nixpkgs/pull/1",
      merge_commit_sha: "abc123"
    }

    id_map = Change.bulk_upsert_all([Map.merge(defaults, attrs)])
    {_number, id} = Enum.at(id_map, 0)
    Ash.get!(Change, id)
  end

  defp create_channel_revision!(channel, revision) do
    ChannelRevision.create!(%{
      channel: channel,
      revision: revision,
      released_at: DateTime.utc_now()
    })
  end

  describe "create/1" do
    test "creates a change_channel linking a change to a channel" do
      change = create_change!()

      {:ok, cc} =
        ChangeChannel.create(%{
          change_id: change.id,
          channel: "nixos-unstable",
          landed_at: ~U[2026-04-01 12:00:00Z]
        })

      assert cc.change_id == change.id
      assert cc.channel == "nixos-unstable"
      assert cc.landed_at == ~U[2026-04-01 12:00:00Z]
      assert is_nil(cc.channel_revision_id)
    end

    test "can optionally link to a channel_revision" do
      change = create_change!()
      rev = create_channel_revision!("nixos-unstable", "abc123def456")

      {:ok, cc} =
        ChangeChannel.create(%{
          change_id: change.id,
          channel: "nixos-unstable",
          landed_at: ~U[2026-04-01 12:00:00Z],
          channel_revision_id: rev.id
        })

      assert cc.channel_revision_id == rev.id
    end

    test "upserts on change_id + channel" do
      change = create_change!()
      rev = create_channel_revision!("nixos-unstable", "abc123def456")

      {:ok, cc1} =
        ChangeChannel.create(%{
          change_id: change.id,
          channel: "nixos-unstable",
          landed_at: ~U[2026-04-01 12:00:00Z]
        })

      {:ok, cc2} =
        ChangeChannel.create(%{
          change_id: change.id,
          channel: "nixos-unstable",
          landed_at: ~U[2026-04-01 14:00:00Z],
          channel_revision_id: rev.id
        })

      assert cc1.id == cc2.id
      assert cc2.channel_revision_id == rev.id
      assert cc2.landed_at == ~U[2026-04-01 14:00:00Z]
    end
  end

  describe "relationships" do
    test "change has_many change_channels" do
      change = create_change!()

      ChangeChannel.create!(%{
        change_id: change.id,
        channel: "nixos-unstable",
        landed_at: ~U[2026-04-01 12:00:00Z]
      })

      ChangeChannel.create!(%{
        change_id: change.id,
        channel: "nixos-25.11",
        landed_at: ~U[2026-04-02 12:00:00Z]
      })

      change = Ash.load!(change, :change_channels)
      assert length(change.change_channels) == 2
    end
  end
end

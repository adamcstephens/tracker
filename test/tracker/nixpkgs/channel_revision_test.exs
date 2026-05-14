defmodule Tracker.Nixpkgs.ChannelRevisionTest do
  use Tracker.DataCase, async: true

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

  describe "diff_between/2" do
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

      pkg =
        Tracker.Nixpkgs.Package
        |> Ash.Changeset.for_create(:create, %{attribute: "diff-between-pkg"})
        |> Ash.create!()

      Tracker.Nixpkgs.PackageRevision.load!(%{
        version: "1.0.0",
        package_id: pkg.id,
        channel_revision_id: from_rev.id
      })

      Tracker.Nixpkgs.PackageRevision.load!(%{
        version: "1.1.0",
        package_id: pkg.id,
        channel_revision_id: to_rev.id
      })

      Tracker.Nixpkgs.PackageEvent
      |> Ash.Changeset.for_create(:create, %{
        type: :added,
        package_id: pkg.id,
        channel_revision_id: to_rev.id
      })
      |> Ash.create!()

      %{"diff-between.opt" => opt_id} =
        Tracker.Nixpkgs.Option.bulk_upsert_all([%{name: "diff-between.opt"}])

      Tracker.Nixpkgs.OptionRevision.load!(%{
        option_id: opt_id,
        channel_revision_id: from_rev.id,
        description: "old",
        type: "boolean",
        default: "false",
        example: nil,
        read_only: false
      })

      Tracker.Nixpkgs.OptionRevision.load!(%{
        option_id: opt_id,
        channel_revision_id: to_rev.id,
        description: "new",
        type: "boolean",
        default: "false",
        example: nil,
        read_only: false
      })

      Tracker.Nixpkgs.OptionEvent
      |> Ash.Changeset.for_create(:create, %{
        type: :added,
        option_id: opt_id,
        channel_revision_id: to_rev.id
      })
      |> Ash.create!()

      %{from_rev: from_rev, to_rev: to_rev}
    end

    test "returns a RevisionDiff populated from the four sources", %{
      from_rev: from_rev,
      to_rev: to_rev
    } do
      diff = ChannelRevision.diff_between(from_rev, to_rev)

      assert %ChannelRevision.RevisionDiff{} = diff
      assert [pkg_event] = diff.package_events
      assert pkg_event.type == :added

      assert [version_change] = diff.version_changes
      assert version_change.attribute == "diff-between-pkg"
      assert version_change.old_version == "1.0.0"
      assert version_change.new_version == "1.1.0"

      assert [opt_event] = diff.option_events
      assert opt_event.type == :added

      assert [metadata_change] = diff.option_metadata_changes
      assert metadata_change.option_name == "diff-between.opt"
    end
  end
end

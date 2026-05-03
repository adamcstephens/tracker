defmodule Tracker.Nixpkgs.ChangeBranchTest do
  use Tracker.DataCase, async: true

  alias Tracker.Nixpkgs.{Branch, Change, ChangeBranch, Channel, ChannelRevision}

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

  defp create_branch!(name, kind \\ :branch, channel_id \\ nil) do
    Branch.create!(%{name: name, kind: kind, channel_id: channel_id})
  end

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
    test "creates a change_branch linking a change to a branch" do
      change = create_change!()
      branch = create_branch!("master")

      {:ok, cb} =
        ChangeBranch.create(%{
          change_id: change.id,
          branch_id: branch.id,
          arrived_at: ~U[2026-04-01 12:00:00Z]
        })

      assert cb.change_id == change.id
      assert cb.branch_id == branch.id
      assert cb.arrived_at == ~U[2026-04-01 12:00:00Z]
      assert is_nil(cb.channel_revision_id)
    end

    test "can optionally link a channel_revision" do
      change = create_change!()
      channel = create_channel!("nixos-unstable")
      branch = create_branch!("nixos-unstable", :channel, channel.id)

      rev =
        ChannelRevision.create!(%{
          channel_id: channel.id,
          revision: "abc123def456",
          released_at: DateTime.utc_now()
        })

      {:ok, cb} =
        ChangeBranch.create(%{
          change_id: change.id,
          branch_id: branch.id,
          arrived_at: ~U[2026-04-01 12:00:00Z],
          channel_revision_id: rev.id
        })

      assert cb.channel_revision_id == rev.id
    end

    test "upserts on (change_id, branch_id)" do
      change = create_change!()
      branch = create_branch!("master")

      {:ok, cb1} =
        ChangeBranch.create(%{
          change_id: change.id,
          branch_id: branch.id,
          arrived_at: ~U[2026-04-01 12:00:00Z]
        })

      {:ok, cb2} =
        ChangeBranch.create(%{
          change_id: change.id,
          branch_id: branch.id,
          arrived_at: ~U[2026-04-01 14:00:00Z]
        })

      assert cb1.id == cb2.id
      assert cb2.arrived_at == ~U[2026-04-01 14:00:00Z]
    end
  end

  describe "relationships" do
    test "change has_many change_branches" do
      change = create_change!()
      branch1 = create_branch!("master")
      branch2 = create_branch!("staging")

      ChangeBranch.create!(%{
        change_id: change.id,
        branch_id: branch1.id,
        arrived_at: ~U[2026-04-01 12:00:00Z]
      })

      ChangeBranch.create!(%{
        change_id: change.id,
        branch_id: branch2.id,
        arrived_at: ~U[2026-04-01 13:00:00Z]
      })

      change = Ash.load!(change, :change_branches)
      assert length(change.change_branches) == 2
    end

    test "branch has_many change_branches" do
      change1 = create_change!()
      change2 = create_change!()
      branch = create_branch!("master")

      ChangeBranch.create!(%{
        change_id: change1.id,
        branch_id: branch.id,
        arrived_at: ~U[2026-04-01 12:00:00Z]
      })

      ChangeBranch.create!(%{
        change_id: change2.id,
        branch_id: branch.id,
        arrived_at: ~U[2026-04-01 13:00:00Z]
      })

      branch = Ash.load!(branch, :change_branches)
      assert length(branch.change_branches) == 2
    end
  end
end

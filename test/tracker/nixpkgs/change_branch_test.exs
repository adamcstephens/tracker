defmodule Tracker.Nixpkgs.ChangeBranchTest do
  use Tracker.DataCase, async: true

  alias Tracker.Nixpkgs.{Change, ChangeBranch, Channel, ChannelRevision}

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

  defp create_channel!(name) do
    Channel.create!(%{
      name: name,
      display_name: name,
      status: :active,
      is_stable: false
    })
  end

  describe "create/1" do
    test "creates a change_branch linking a change to a branch_name" do
      change = create_change!()

      {:ok, cb} =
        ChangeBranch.create(%{change_id: change.id, branch_name: "master"})

      assert cb.change_id == change.id
      assert cb.branch_name == "master"
      assert is_nil(cb.channel_revision_id)
    end

    test "can optionally link a channel_revision" do
      change = create_change!()
      channel = create_channel!("nixos-unstable")

      rev =
        ChannelRevision.create!(%{
          channel_id: channel.id,
          revision: "abc123def456",
          released_at: DateTime.utc_now()
        })

      {:ok, cb} =
        ChangeBranch.create(%{
          change_id: change.id,
          branch_name: "nixos-unstable",
          channel_revision_id: rev.id
        })

      assert cb.channel_revision_id == rev.id
    end

    test "upserts on (change_id, branch_name)" do
      change = create_change!()

      {:ok, cb1} =
        ChangeBranch.create(%{change_id: change.id, branch_name: "master"})

      {:ok, cb2} =
        ChangeBranch.create(%{change_id: change.id, branch_name: "master"})

      assert cb1.id == cb2.id
    end

    test "rejects unknown branch_name" do
      change = create_change!()

      assert {:error, _} =
               ChangeBranch.create(%{
                 change_id: change.id,
                 branch_name: "totally-not-a-branch"
               })
    end

    test "accepts versioned release branches" do
      change = create_change!()

      {:ok, cb} =
        ChangeBranch.create(%{change_id: change.id, branch_name: "release-25.11"})

      assert cb.branch_name == "release-25.11"
    end
  end

  describe "relationships" do
    test "change has_many change_branches" do
      change = create_change!()

      ChangeBranch.create!(%{change_id: change.id, branch_name: "master"})
      ChangeBranch.create!(%{change_id: change.id, branch_name: "staging"})

      change = Ash.load!(change, :change_branches)
      assert length(change.change_branches) == 2
    end
  end
end

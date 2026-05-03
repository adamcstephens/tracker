defmodule Tracker.Nixpkgs.BranchTest do
  use Tracker.DataCase, async: true

  alias Tracker.Nixpkgs.{Branch, Channel}

  describe "create/1" do
    test "creates a branch with kind :branch" do
      {:ok, branch} = Branch.create(%{name: "master", kind: :branch})

      assert branch.name == "master"
      assert branch.kind == :branch
      assert is_nil(branch.channel_id)
    end

    test "creates a channel-kind branch linked to a Channel" do
      channel =
        Channel.create!(%{
          name: "nixos-unstable",
          display_name: "nixos-unstable",
          branch: "nixos-unstable",
          status: :active,
          is_stable: false
        })

      {:ok, branch} =
        Branch.create(%{name: "nixos-unstable", kind: :channel, channel_id: channel.id})

      assert branch.kind == :channel
      assert branch.channel_id == channel.id
    end

    test "rejects unknown kind" do
      assert {:error, _} = Branch.create(%{name: "master", kind: :weird})
    end

    test "upserts on name" do
      {:ok, b1} = Branch.create(%{name: "master", kind: :branch})
      {:ok, b2} = Branch.create(%{name: "master", kind: :branch})
      assert b1.id == b2.id
    end
  end

  describe "by_name/1" do
    test "fetches by name" do
      {:ok, _} = Branch.create(%{name: "master", kind: :branch})
      assert {:ok, branch} = Branch.by_name("master")
      assert branch.name == "master"
    end

    test "returns error when missing" do
      assert {:error, _} = Branch.by_name("nope")
    end
  end
end

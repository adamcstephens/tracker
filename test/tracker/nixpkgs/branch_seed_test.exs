defmodule Tracker.Nixpkgs.BranchSeedTest do
  use Tracker.DataCase, async: false

  alias Tracker.Nixpkgs.{Branch, Channel}

  setup do
    Channel.create!(%{
      name: "nixos-25.11",
      display_name: "nixos-25.11",
      branch: "nixos-25.11",
      status: :active,
      is_stable: true
    })

    Channel.create!(%{
      name: "nixos-25.11-small",
      display_name: "nixos-25.11-small",
      branch: "nixos-25.11-small",
      status: :active,
      is_stable: true
    })

    Channel.create!(%{
      name: "nixos-unstable",
      display_name: "nixos-unstable",
      branch: "nixos-unstable",
      status: :active,
      is_stable: false
    })

    Channel.create!(%{
      name: "nixos-unstable-small",
      display_name: "nixos-unstable-small",
      branch: "nixos-unstable-small",
      status: :active,
      is_stable: false
    })

    Channel.create!(%{
      name: "nixpkgs-unstable",
      display_name: "nixpkgs-unstable",
      branch: "nixpkgs-unstable",
      status: :active,
      is_stable: false
    })

    :ok
  end

  test "seeds static branches" do
    Branch.seed!()

    assert {:ok, master} = Branch.by_name("master")
    assert master.kind == :branch
    assert is_nil(master.channel_id)

    assert {:ok, staging} = Branch.by_name("staging")
    assert staging.kind == :branch
  end

  test "seeds versioned branches from active stable channels" do
    Branch.seed!()

    assert {:ok, staging_2511} = Branch.by_name("staging-25.11")
    assert staging_2511.kind == :branch

    assert {:ok, release_2511} = Branch.by_name("release-25.11")
    assert release_2511.kind == :branch
  end

  test "links channel-kind branches to their channels" do
    Branch.seed!()

    {:ok, channel} = Channel.by_name("nixos-unstable")
    assert {:ok, branch} = Branch.by_name("nixos-unstable")
    assert branch.kind == :channel
    assert branch.channel_id == channel.id
  end

  test "is idempotent" do
    Branch.seed!()
    count1 = length(Branch.read!())

    Branch.seed!()
    assert length(Branch.read!()) == count1
  end
end

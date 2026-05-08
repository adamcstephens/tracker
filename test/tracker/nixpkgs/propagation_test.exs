defmodule Tracker.Nixpkgs.PropagationTest do
  use ExUnit.Case, async: true

  alias Tracker.Nixpkgs.Propagation
  alias Tracker.Nixpkgs.Propagation.{Dag, Edge}

  describe "next_branches/1" do
    test "master flows to nixos-unstable-small and nixpkgs-unstable" do
      assert Enum.sort(Propagation.next_branches("master")) ==
               ["nixos-unstable-small", "nixpkgs-unstable"]
    end

    test "staging flows to staging-next" do
      assert Propagation.next_branches("staging") == ["staging-next"]
    end

    test "staging-next flows to master" do
      assert Propagation.next_branches("staging-next") == ["master"]
    end

    test "haskell-updates flows to staging" do
      assert Propagation.next_branches("haskell-updates") == ["staging"]
    end

    test "staging-nixos flows to master" do
      assert Propagation.next_branches("staging-nixos") == ["master"]
    end

    test "nixos-unstable-small flows to nixos-unstable" do
      assert Propagation.next_branches("nixos-unstable-small") == ["nixos-unstable"]
    end

    test "terminal channels have no successors" do
      assert Propagation.next_branches("nixos-unstable") == []
      assert Propagation.next_branches("nixpkgs-unstable") == []
    end

    test "versioned staging flows to versioned staging-next" do
      assert Propagation.next_branches("staging-25.11") == ["staging-next-25.11"]
    end

    test "versioned staging-next flows to release branch" do
      assert Propagation.next_branches("staging-next-25.11") == ["release-25.11"]
    end

    test "release branch flows to versioned nixos-small and nixpkgs-darwin" do
      assert Enum.sort(Propagation.next_branches("release-25.11")) ==
               ["nixos-25.11-small", "nixpkgs-25.11-darwin"]
    end

    test "versioned nixos-small flows to versioned nixos" do
      assert Propagation.next_branches("nixos-25.11-small") == ["nixos-25.11"]
    end

    test "versioned terminal channel has no successors" do
      assert Propagation.next_branches("nixos-25.11") == []
    end

    test "unknown branch returns empty" do
      assert Propagation.next_branches("nonsense") == []
    end
  end

  describe "downstream/1" do
    test "from master reaches all unstable terminals" do
      downstream = Propagation.downstream("master")
      assert "nixos-unstable-small" in downstream
      assert "nixos-unstable" in downstream
      assert "nixpkgs-unstable" in downstream
    end

    test "from staging reaches master and beyond" do
      downstream = Propagation.downstream("staging")
      assert "staging-next" in downstream
      assert "master" in downstream
      assert "nixos-unstable" in downstream
    end

    test "does not include the starting branch" do
      downstream = Propagation.downstream("master")
      refute "master" in downstream
    end

    test "from release-25.11 reaches nixos-25.11 and nixpkgs-25.11-darwin" do
      downstream = Propagation.downstream("release-25.11")
      assert "nixos-25.11-small" in downstream
      assert "nixos-25.11" in downstream
      assert "nixpkgs-25.11-darwin" in downstream
    end

    test "stable propagation does not reach unstable channels" do
      downstream = Propagation.downstream("release-25.11")
      refute "nixos-unstable" in downstream
      refute "master" in downstream
    end

    test "terminal channel has empty downstream" do
      assert Propagation.downstream("nixos-unstable") == []
    end
  end

  describe "terminal_channels/1" do
    test "from master returns the unstable channels" do
      assert Enum.sort(Propagation.terminal_channels("master")) ==
               ["nixos-unstable", "nixos-unstable-small", "nixpkgs-unstable"]
    end

    test "from staging returns the same set as master" do
      assert Enum.sort(Propagation.terminal_channels("staging")) ==
               Enum.sort(Propagation.terminal_channels("master"))
    end

    test "from release-25.11 returns versioned channels" do
      assert Enum.sort(Propagation.terminal_channels("release-25.11")) ==
               ["nixos-25.11", "nixos-25.11-small", "nixpkgs-25.11-darwin"]
    end

    test "channel itself is included when starting from a channel" do
      assert "nixos-unstable" in Propagation.terminal_channels("nixos-unstable")
    end
  end

  describe "ancestors_of/1" do
    test "nixos-unstable has master and staging in ancestors" do
      ancestors = Propagation.ancestors_of("nixos-unstable")
      assert "nixos-unstable-small" in ancestors
      assert "master" in ancestors
      assert "staging-next" in ancestors
      assert "staging" in ancestors
      assert "haskell-updates" in ancestors
    end

    test "does not include the channel itself" do
      ancestors = Propagation.ancestors_of("nixos-unstable")
      refute "nixos-unstable" in ancestors
    end

    test "nixos-25.11 has versioned ancestors only" do
      ancestors = Propagation.ancestors_of("nixos-25.11")
      assert "nixos-25.11-small" in ancestors
      assert "release-25.11" in ancestors
      assert "staging-next-25.11" in ancestors
      assert "staging-25.11" in ancestors
      refute "master" in ancestors
      refute "nixos-unstable" in ancestors
    end
  end

  describe "kind/1" do
    test "nixos-* and nixpkgs-* are channels" do
      assert Propagation.kind("nixos-unstable") == :channel
      assert Propagation.kind("nixos-unstable-small") == :channel
      assert Propagation.kind("nixos-25.11") == :channel
      assert Propagation.kind("nixos-25.11-small") == :channel
      assert Propagation.kind("nixpkgs-unstable") == :channel
      assert Propagation.kind("nixpkgs-25.11-darwin") == :channel
    end

    test "intermediate refs are branches" do
      assert Propagation.kind("master") == :branch
      assert Propagation.kind("staging") == :branch
      assert Propagation.kind("staging-next") == :branch
      assert Propagation.kind("staging-25.11") == :branch
      assert Propagation.kind("release-25.11") == :branch
      assert Propagation.kind("haskell-updates") == :branch
      assert Propagation.kind("staging-nixos") == :branch
    end
  end

  describe "branches_for_release/1" do
    test "expands a release version to all its versioned branches" do
      branches = Propagation.branches_for_release("25.11")
      assert "staging-25.11" in branches
      assert "staging-next-25.11" in branches
      assert "release-25.11" in branches
      assert "nixos-25.11-small" in branches
      assert "nixos-25.11" in branches
      assert "nixpkgs-25.11-darwin" in branches
    end
  end

  describe "static_branches/0" do
    test "lists the master-line refs" do
      branches = Propagation.static_branches()
      assert "master" in branches
      assert "staging" in branches
      assert "staging-next" in branches
      assert "staging-nixos" in branches
      assert "haskell-updates" in branches
      assert "nixos-unstable" in branches
      assert "nixos-unstable-small" in branches
      assert "nixpkgs-unstable" in branches
    end
  end

  describe "lifecycle/2" do
    test "from master includes the root and all descendants" do
      %{nodes: nodes} = Propagation.lifecycle("master", [])

      names = Enum.map(nodes, & &1.name)
      assert "master" in names
      assert "nixpkgs-unstable" in names
      assert "nixos-unstable-small" in names
      assert "nixos-unstable" in names
    end

    test "marks present branches and leaves the rest pending" do
      %{nodes: nodes} = Propagation.lifecycle("master", ["master", "nixpkgs-unstable"])

      by_name = Map.new(nodes, &{&1.name, &1})
      assert by_name["master"].present
      assert by_name["nixpkgs-unstable"].present
      refute by_name["nixos-unstable-small"].present
      refute by_name["nixos-unstable"].present
    end

    test "assigns levels by BFS depth from the root" do
      %{nodes: nodes} = Propagation.lifecycle("master", [])
      by_name = Map.new(nodes, &{&1.name, &1})

      assert by_name["master"].level == 0
      assert by_name["nixpkgs-unstable"].level == 1
      assert by_name["nixos-unstable-small"].level == 1
      assert by_name["nixos-unstable"].level == 2
    end

    test "tags each node with its kind" do
      %{nodes: nodes} = Propagation.lifecycle("master", [])
      by_name = Map.new(nodes, &{&1.name, &1})

      assert by_name["master"].kind == :branch
      assert by_name["nixpkgs-unstable"].kind == :channel
      assert by_name["nixos-unstable"].kind == :channel
    end

    test "edges are restricted to nodes within the DAG" do
      %{edges: edges} = Propagation.lifecycle("master", [])

      assert %Edge{from: "master", to: "nixpkgs-unstable"} in edges
      assert %Edge{from: "master", to: "nixos-unstable-small"} in edges
      assert %Edge{from: "nixos-unstable-small", to: "nixos-unstable"} in edges

      from_branches = Enum.map(edges, & &1.from)
      to_branches = Enum.map(edges, & &1.to)
      refute "haskell-updates" in from_branches
      refute "staging" in to_branches
    end

    test "from staging covers the full chain through master" do
      %{nodes: nodes} = Propagation.lifecycle("staging", [])
      by_name = Map.new(nodes, &{&1.name, &1})

      assert by_name["staging"].level == 0
      assert by_name["staging-next"].level == 1
      assert by_name["master"].level == 2
      assert by_name["nixos-unstable"].level == 4
    end

    test "from versioned release stays in the release line" do
      %{nodes: nodes} = Propagation.lifecycle("release-25.11", [])

      names = Enum.map(nodes, & &1.name)
      assert "release-25.11" in names
      assert "nixos-25.11-small" in names
      assert "nixos-25.11" in names
      assert "nixpkgs-25.11-darwin" in names
      refute "master" in names
      refute "nixos-unstable" in names
    end

    test "unknown base_ref returns an empty DAG" do
      assert Propagation.lifecycle("not-a-branch", []) == %Dag{nodes: [], edges: []}
    end

    test "nil base_ref returns an empty DAG" do
      assert Propagation.lifecycle(nil, []) == %Dag{nodes: [], edges: []}
    end
  end
end

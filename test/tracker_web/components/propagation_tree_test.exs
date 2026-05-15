defmodule TrackerWeb.PropagationTreeTest do
  use ExUnit.Case, async: true

  alias Tracker.Nixpkgs.Propagation
  alias TrackerWeb.PropagationTree

  describe "build/2" do
    test "returns nil for an empty DAG" do
      assert PropagationTree.build(%Propagation.Dag{nodes: [], edges: []}) == nil
    end

    test "roots the spanning tree at base_ref and nests downstream branches" do
      dag = Propagation.lifecycle("master", ["master", "nixos-unstable-small"])
      tree = PropagationTree.build(dag)

      assert tree.name == "master"
      assert tree.present == true

      child_names = Enum.map(tree.children, & &1.name) |> Enum.sort()
      assert child_names == ["nixos-unstable-small", "nixpkgs-unstable"]

      small = Enum.find(tree.children, &(&1.name == "nixos-unstable-small"))
      assert small.present == true
      assert Enum.map(small.children, & &1.name) == ["nixos-unstable"]

      [unstable] = small.children
      assert unstable.present == false
      assert unstable.children == []
    end

    test "marks the configured branch with mine?: true" do
      dag = Propagation.lifecycle("master", [])
      tree = PropagationTree.build(dag, mine_branch: "nixos-unstable")

      small = Enum.find(tree.children, &(&1.name == "nixos-unstable-small"))
      [unstable] = small.children

      assert unstable.mine? == true
      assert small.mine? == false
      assert tree.mine? == false
    end

    test "carries the node kind for downstream styling" do
      dag = Propagation.lifecycle("master", [])
      tree = PropagationTree.build(dag)

      small = Enum.find(tree.children, &(&1.name == "nixos-unstable-small"))
      [unstable] = small.children

      assert tree.kind == :branch
      assert small.kind == :channel
      assert unstable.kind == :channel
    end

    test "handles a release line as the root" do
      dag = Propagation.lifecycle("release-25.05", [])
      tree = PropagationTree.build(dag)

      assert tree.name == "release-25.05"

      child_names = Enum.map(tree.children, & &1.name) |> Enum.sort()
      assert "nixos-25.05-small" in child_names
      assert "nixpkgs-25.05-darwin" in child_names

      small = Enum.find(tree.children, &(&1.name == "nixos-25.05-small"))
      assert Enum.map(small.children, & &1.name) == ["nixos-25.05"]
    end
  end
end

defmodule TrackerWeb.PropagationTree do
  @moduledoc """
  Renders a propagation lifecycle DAG as a vertical branch tree (mobile).

  Unlike `TrackerWeb.PropagationDag` (which lays out the DAG as inline SVG
  for desktop), this component converts the DAG into a spanning tree rooted
  at the change's `base_ref` and renders it as a nested `<ul>` with CSS
  elbow connectors. Each node is tagged `:is-done` when the change is
  present on that branch and `:is-mine` when it matches the configured
  user channel.

  The tree shape is derived from the real propagation graph — no manual
  layout. The DAGs we currently care about (rooted at `master`, `staging`,
  or a `release-X.Y`) happen to be trees, so a simple BFS-with-first-parent
  walk gives an accurate rendering with no shared descendants to collapse.
  """
  use TrackerWeb, :html

  alias Tracker.Nixpkgs.Propagation.Dag
  alias TrackerWeb.PropagationDag.BranchLink

  use TypedStruct

  typedstruct module: Node, enforce: true do
    field :name, String.t()
    field :kind, :branch | :channel
    field :present, boolean()
    field :mine?, boolean()
    field :children, [t()]
  end

  @doc """
  Builds a spanning tree rooted at the lowest-level node in `dag` (the
  change's `base_ref`). Returns `nil` for an empty DAG.

  Options:
    * `:mine_branch` — branch name to flag with `mine?: true`.
  """
  @spec build(Dag.t(), keyword()) :: Node.t() | nil
  def build(dag, opts \\ [])
  def build(%Dag{nodes: []}, _opts), do: nil

  def build(%Dag{nodes: nodes, edges: edges}, opts) do
    mine = Keyword.get(opts, :mine_branch)
    root = Enum.min_by(nodes, & &1.level)
    by_name = Map.new(nodes, &{&1.name, &1})

    children_of =
      Enum.reduce(edges, %{}, fn %{from: f, to: t}, acc ->
        Map.update(acc, f, [t], &[t | &1])
      end)

    do_build(root.name, by_name, children_of, mine, MapSet.new())
  end

  defp do_build(name, by_name, children_of, mine, seen) do
    seen = MapSet.put(seen, name)
    node = Map.fetch!(by_name, name)

    child_names =
      children_of
      |> Map.get(name, [])
      |> Enum.reject(&MapSet.member?(seen, &1))
      |> Enum.sort()

    %Node{
      name: node.name,
      kind: node.kind,
      present: node.present,
      mine?: name == mine,
      children: Enum.map(child_names, &do_build(&1, by_name, children_of, mine, seen))
    }
  end

  attr :tree, Node, default: nil
  attr :branch_links, :map, default: %{}

  @doc """
  Renders the branch tree. Renders nothing when `tree` is nil.
  """
  def tree(assigns) do
    ~H"""
    <ul :if={@tree} class="m4-tree">
      <.tree_node node={@tree} branch_links={@branch_links} />
    </ul>
    """
  end

  attr :node, Node, required: true
  attr :branch_links, :map, required: true

  defp tree_node(assigns) do
    ~H"""
    <li class={node_class(@node)} data-branch={@node.name}>
      <div class="m4-row">
        <span class="m4-node" aria-hidden="true">{node_glyph(@node)}</span>
        <div class="m4-row-body">
          <.node_label node={@node} link={Map.get(@branch_links, @node.name)} />
          <div class="m4-node-sub">{level_text(@node)}</div>
        </div>
      </div>
      <ul :if={@node.children != []} class={node_children_class(@node)}>
        <.tree_node :for={child <- @node.children} node={child} branch_links={@branch_links} />
      </ul>
    </li>
    """
  end

  attr :node, Node, required: true
  attr :link, BranchLink, default: nil

  defp node_label(%{link: nil} = assigns) do
    ~H"""
    <div class="m4-node-name">{@node.name}</div>
    """
  end

  defp node_label(assigns) do
    ~H"""
    <div class="m4-node-name">
      <.link navigate={~p"/channels/#{@link.channel_name}/revisions/#{@link.revision}"}>
        {@node.name}
      </.link>
    </div>
    """
  end

  defp node_class(%Node{present: true, mine?: true}), do: "is-done is-mine"
  defp node_class(%Node{present: true}), do: "is-done"
  defp node_class(%Node{mine?: true}), do: "is-mine"
  defp node_class(_), do: nil

  defp node_children_class(%Node{present: true}), do: "is-live"
  defp node_children_class(_), do: nil

  defp node_glyph(%Node{present: true}), do: "✓"
  defp node_glyph(_), do: "○"

  defp level_text(%Node{kind: :channel}), do: "Channel"
  defp level_text(%Node{kind: :branch, children: []}), do: "Branch"
  defp level_text(%Node{kind: :branch}), do: "Branch"
end

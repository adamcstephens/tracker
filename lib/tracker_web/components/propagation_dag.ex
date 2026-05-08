defmodule TrackerWeb.PropagationDag do
  @moduledoc """
  Renders a propagation lifecycle DAG as inline SVG.

  Active nodes (those where the change has a recorded ChangeBranch) are
  filled; pending nodes are shown in muted styling. Edges connect each
  node to its direct successors per `Tracker.Nixpkgs.Propagation`.
  """
  use Phoenix.Component

  alias Tracker.Nixpkgs.Propagation.Dag

  @node_w 170
  @node_h 28
  @col_gap 40
  @row_gap 12
  @padding 8

  attr :dag, Dag, required: true

  def dag(assigns) do
    layout = layout(assigns.dag)
    assigns = assign(assigns, :layout, layout)

    ~H"""
    <div :if={@layout.empty?} class="propagation-dag-empty">
      <em>No propagation graph available for this base branch.</em>
    </div>
    <svg
      :if={not @layout.empty?}
      class="propagation-dag"
      role="img"
      aria-label="Propagation lifecycle"
      viewBox={"0 0 #{@layout.width} #{@layout.height}"}
      width={@layout.width}
      height={@layout.height}
    >
      <line
        :for={edge <- @layout.edges}
        x1={edge.x1}
        y1={edge.y1}
        x2={edge.x2}
        y2={edge.y2}
        stroke={edge.stroke}
        stroke-width="1.5"
      />
      <g :for={node <- @layout.nodes} class={node_class(node)} data-branch={node.name}>
        <rect
          x={node.x}
          y={node.y}
          width={node.width}
          height={node.height}
          rx="4"
          ry="4"
          fill={node.fill}
          stroke={node.stroke}
          stroke-width="1.5"
        />
        <text
          x={node.x + node.width / 2}
          y={node.y + node.height / 2 + 4}
          text-anchor="middle"
          font-size="12"
          font-family="ui-monospace, SFMono-Regular, Menlo, monospace"
          fill={node.text_fill}
        >
          {node.name}
        </text>
      </g>
    </svg>
    """
  end

  defp node_class(%{present: true}), do: "propagation-node propagation-node-present"
  defp node_class(%{present: false}), do: "propagation-node propagation-node-pending"

  @doc false
  def layout(%Dag{nodes: []}), do: %{empty?: true}

  def layout(%Dag{nodes: nodes, edges: edges}) do
    by_level = Enum.group_by(nodes, & &1.level)
    max_per_level = by_level |> Map.values() |> Enum.map(&length/1) |> Enum.max()
    max_level = nodes |> Enum.map(& &1.level) |> Enum.max()

    positions =
      by_level
      |> Enum.flat_map(fn {level, level_nodes} ->
        level_nodes
        |> Enum.sort_by(& &1.name)
        |> Enum.with_index()
        |> Enum.map(fn {node, idx} -> {node.name, position(node, level, idx)} end)
      end)
      |> Map.new()

    rendered_nodes =
      nodes
      |> Enum.map(fn node ->
        pos = Map.fetch!(positions, node.name)

        %{
          name: node.name,
          present: node.present,
          x: pos.x,
          y: pos.y,
          width: @node_w,
          height: @node_h,
          fill: fill_for(node),
          stroke: stroke_for(node),
          text_fill: text_fill_for(node)
        }
      end)

    rendered_edges =
      Enum.map(edges, fn edge ->
        from = Map.fetch!(positions, edge.from)
        to = Map.fetch!(positions, edge.to)

        %{
          x1: from.x + @node_w,
          y1: from.y + @node_h / 2,
          x2: to.x,
          y2: to.y + @node_h / 2,
          stroke: "var(--pico-muted-border-color, #aaa)"
        }
      end)

    width = (max_level + 1) * @node_w + max_level * @col_gap + 2 * @padding
    height = max_per_level * @node_h + max(max_per_level - 1, 0) * @row_gap + 2 * @padding

    %{
      empty?: false,
      width: width,
      height: height,
      nodes: rendered_nodes,
      edges: rendered_edges
    }
  end

  defp position(_node, level, idx) do
    %{
      x: @padding + level * (@node_w + @col_gap),
      y: @padding + idx * (@node_h + @row_gap)
    }
  end

  defp fill_for(%{present: true}), do: "var(--pico-primary-background, #1095c1)"
  defp fill_for(%{present: false}), do: "var(--pico-card-background-color, #f6f8fa)"

  defp stroke_for(%{present: true}), do: "var(--pico-primary, #1095c1)"
  defp stroke_for(%{present: false}), do: "var(--pico-muted-border-color, #c8ced4)"

  defp text_fill_for(%{present: true}), do: "var(--pico-primary-inverse, #fff)"
  defp text_fill_for(%{present: false}), do: "var(--pico-muted-color, #6c757d)"
end

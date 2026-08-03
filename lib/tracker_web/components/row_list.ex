defmodule TrackerWeb.RowList do
  @moduledoc """
  The app's list idiom: one card with internal dividers, one row per item.

  A row is a label, optional trailing meta and actions, and — in expandable
  mode — a body that opens beneath it.
  """
  use Phoenix.Component

  @doc """
  Renders the list container. Rows go in the inner block as `row/1` calls.

  ## Examples

      <.row_list id="options-list" phx-hook="AnchorExpand">
        <.row :for={opt <- @options} id={"opt-\#{opt.name}"} mode={:expandable}>
          <:label>{opt.name}</:label>
          <:meta>{opt.type}</:meta>
          <:body>{opt.description}</:body>
        </.row>
      </.row_list>
  """
  attr :id, :string, required: true

  attr :stacked, :boolean,
    default: false,
    doc: "drop meta and actions onto their own line on narrow screens"

  attr :rest, :global

  slot :inner_block, required: true

  def row_list(assigns) do
    ~H"""
    <ul id={@id} class={row_list_class(@stacked)} {@rest}>
      {render_slot(@inner_block)}
    </ul>
    """
  end

  defp row_list_class(true), do: "row-list row-list--stacked"
  defp row_list_class(false), do: "row-list"

  @doc """
  Renders one row.

  Modes:

    * `:expandable` — a `<details>` row that opens its `:body`. With no
      `:body` it degrades to a plain row rather than an empty panel.
    * `:link` — the whole row navigates to `navigate`.
    * `:plain` — a bare row.
  """
  attr :id, :string, default: nil
  attr :mode, :atom, default: :plain, values: [:expandable, :link, :plain]
  attr :navigate, :string, default: nil, doc: "destination for :link mode"
  attr :open, :boolean, default: false, doc: "expanded on first render, :expandable mode"

  slot :label, required: true
  slot :meta
  slot :actions
  slot :body

  def row(%{mode: :expandable, body: [_ | _]} = assigns) do
    ~H"""
    <li>
      <details id={@id} open={@open}>
        <summary class="row-line">
          <.row_content label={@label} meta={@meta} actions={@actions} />
        </summary>
        {render_slot(@body)}
      </details>
    </li>
    """
  end

  def row(%{mode: :link} = assigns) do
    ~H"""
    <li>
      <.link id={@id} navigate={@navigate} class="row-line row-link">
        <.row_content label={@label} meta={@meta} actions={@actions} />
      </.link>
    </li>
    """
  end

  def row(assigns) do
    ~H"""
    <li>
      <div id={@id} class="row-line">
        <.row_content label={@label} meta={@meta} actions={@actions} />
      </div>
    </li>
    """
  end

  attr :label, :list, required: true
  attr :meta, :list, required: true
  attr :actions, :list, required: true

  defp row_content(assigns) do
    ~H"""
    <span class="row-label">{render_slot(@label)}</span>
    <span :if={@meta != []} class="row-meta">{render_slot(@meta)}</span>
    <span :if={@actions != []} class="row-actions">{render_slot(@actions)}</span>
    """
  end
end

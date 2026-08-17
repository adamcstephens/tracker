defmodule TrackerWeb.RowList do
  @moduledoc """
  The app's list idiom: one card with internal dividers, one row per item.

  A row is an optional leading affordance, a label with an optional second
  line under it, optional trailing meta and actions, and — in expandable
  mode — a body that opens beneath it.

  ## Where content goes

  Each row is its own grid, so columns don't align across rows: a wide
  trailing column shifts that row's meta leftward while its neighbours stay
  put, and on a narrow screen it takes the width the label needed, wrapping
  the label to a character per line.

  So `:meta` and `:actions` are for near-constant-width content — a count, a
  timestamp, a status, an icon button. Anything variable-width (a
  description, an attribute path, a scope sentence, a badge that only some
  rows carry) belongs in `:label` or `:sublabel`, which share the row's one
  flexible column.

  Rows whose meta is wide enough to crowd the label on a phone should pass
  `stacked` to `row_list/1`.

  ## Uniform row height

  Every row in a list is the same height, so paging a list doesn't move the
  controls underneath it. The CSS does this in two parts: a `:sublabel` is
  held to a single line and fades out where it overflows, and a row without
  one still reserves the line, in any list where some row has a sublabel.

  A `:label` is exempt — it can wrap, and a wrapped label does make its row
  taller. It names the row, so truncating it would cost more than the drift
  it saves.
  """
  use TrackerWeb, :html

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
    * `:link` — the whole row navigates to `navigate`. Its `:actions` float at
      the trailing edge outside that link, so an action of their own — an
      outbound link, a button — is reachable without following the row.
    * `:plain` — a bare row.
  """
  attr :id, :string, default: nil
  attr :mode, :atom, default: :plain, values: [:expandable, :link, :plain]
  attr :navigate, :string, default: nil, doc: "destination for :link mode"
  attr :open, :boolean, default: false, doc: "expanded on first render, :expandable mode"
  attr :rest, :global, doc: "row state — class, style, data attributes — applied to the <li>"

  slot :leading, doc: "affordance ahead of the label — a glyph, a checkbox, nothing"
  slot :label, required: true
  slot :sublabel, doc: "secondary line under the label"
  slot :meta
  slot :actions
  slot :body

  def row(%{mode: :expandable, body: [_ | _]} = assigns) do
    ~H"""
    <li id={@id} {@rest}>
      <details open={@open}>
        <summary class={line_class(@leading)}>
          <.row_content
            leading={@leading}
            label={@label}
            sublabel={@sublabel}
            meta={@meta}
            actions={@actions}
          />
        </summary>
        {render_slot(@body)}
      </details>
    </li>
    """
  end

  # Actions float outside the row link: an anchor or button nested in an anchor
  # is invalid, and the parser lifts a nested <a> out of the row entirely.
  def row(%{mode: :link} = assigns) do
    ~H"""
    <li id={@id} {@rest}>
      <.link navigate={@navigate} class={[line_class(@leading), "row-link"]}>
        <.row_content
          leading={@leading}
          label={@label}
          sublabel={@sublabel}
          meta={@meta}
          actions={[]}
        />
      </.link>
      <span :if={@actions != []} class="row-actions row-actions--float">{render_slot(@actions)}</span>
    </li>
    """
  end

  def row(assigns) do
    ~H"""
    <li id={@id} {@rest}>
      <div class={line_class(@leading)} tabindex="-1">
        <.row_content
          leading={@leading}
          label={@label}
          sublabel={@sublabel}
          meta={@meta}
          actions={@actions}
        />
      </div>
    </li>
    """
  end

  defp line_class([]), do: "row-line"
  defp line_class([_ | _]), do: "row-line row-line--leading"

  attr :leading, :list, required: true
  attr :label, :list, required: true
  attr :sublabel, :list, required: true
  attr :meta, :list, required: true
  attr :actions, :list, required: true

  defp row_content(assigns) do
    ~H"""
    <span :if={@leading != []} class="row-leading">{render_slot(@leading)}</span>
    <div :if={@sublabel != []} class="row-body">
      <span class="row-label">{render_slot(@label)}</span>
      <span class="row-sublabel">{render_slot(@sublabel)}</span>
    </div>
    <span :if={@sublabel == []} class="row-label">{render_slot(@label)}</span>
    <span :if={@meta != []} class="row-meta">{render_slot(@meta)}</span>
    <span :if={@actions != []} class="row-actions">{render_slot(@actions)}</span>
    """
  end
end

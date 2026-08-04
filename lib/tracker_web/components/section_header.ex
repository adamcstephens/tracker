defmodule TrackerWeb.SectionHeader do
  @moduledoc """
  The heading above a `TrackerWeb.RowList` — a small uppercase title, a
  hairline rule filling the width the title leaves, and the number of rows
  in the list underneath.

  Affordances for the list — a filter form, a toggle — go in `:controls`,
  which shares the header's line with the title and drops to a line of its
  own on a narrow screen.
  """
  use Phoenix.Component

  @doc """
  Renders the header.

  ## Examples

      <SectionHeader.section_header title="Packages" count={length(@subs)} />
      <RowList.row_list id="package-subscriptions">
        ...
      </RowList.row_list>
  """
  attr :title, :string, required: true
  attr :count, :integer, required: true

  slot :controls, doc: "affordances for the list — a filter form, a toggle, a link"

  def section_header(assigns) do
    ~H"""
    <div class="section-header">
      <h2>{@title}</h2>
      <span class="rule"></span>
      <span :if={@controls != []} class="section-controls">{render_slot(@controls)}</span>
      <span class="n">{@count}</span>
    </div>
    """
  end
end

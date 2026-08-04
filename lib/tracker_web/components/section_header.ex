defmodule TrackerWeb.SectionHeader do
  @moduledoc """
  The heading above a `TrackerWeb.RowList` — a small uppercase title, a
  hairline rule filling the width the title leaves, and the number of rows
  in the list underneath.
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

  def section_header(assigns) do
    ~H"""
    <div class="section-header">
      <h2>{@title}</h2>
      <span class="rule"></span>
      <span class="n">{@count}</span>
    </div>
    """
  end
end

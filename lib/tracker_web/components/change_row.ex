defmodule TrackerWeb.ChangeRow do
  @moduledoc """
  A nixpkgs change as a `TrackerWeb.RowList` row, the same everywhere it appears.

  The row is the change's number and title, a state pill and base branch
  beneath, the merge date trailing, and a link out to GitHub. A caller that
  isn't already scoped to one channel passes `landed_in` to mark the rows that
  reached it.
  """
  use TrackerWeb, :html

  alias TrackerWeb.RowList

  @doc """
  Renders the list container, with the flags a list of changes always wants:
  merge dates are missing on unmerged rows, and titles run long.
  """
  attr :id, :string, required: true
  attr :rest, :global

  slot :inner_block, required: true

  def change_row_list(assigns) do
    ~H"""
    <RowList.row_list id={@id} stacked reserve_meta truncate_label {@rest}>
      {render_slot(@inner_block)}
    </RowList.row_list>
    """
  end

  @doc "Renders one change."
  attr :id, :string, default: nil
  attr :change, :map, required: true
  attr :landed_in, :string, default: nil, doc: "channel this row is marked as having reached"

  def change_row(assigns) do
    ~H"""
    <RowList.row id={@id} mode={:link} navigate={~p"/changes/#{@change.number}"}>
      <:label>
        <span class="row-num">#{@change.number}</span> {@change.title}
      </:label>
      <:sublabel>
        <span class={"pill pill-#{@change.state}"}>
          <span class="dot" aria-hidden="true"></span>
          {@change.state}
        </span>
        <span>{@change.base_ref}</span>
        <span :if={@landed_in} class="pill pill-landed">
          in {@landed_in}
        </span>
      </:sublabel>
      <:meta>{merged_on(@change.merged_at)}</:meta>
      <:actions>
        <a
          href={@change.url}
          target="_blank"
          rel="noopener noreferrer"
          class="row-action"
          title="Open on GitHub"
          aria-label={"Open ##{@change.number} on GitHub"}
          data-external-link
        >
          <.external_icon />
        </a>
      </:actions>
    </RowList.row>
    """
  end

  defp external_icon(assigns) do
    ~H"""
    <svg
      class="icon-external"
      aria-hidden="true"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.7"
      stroke-linecap="round"
      stroke-linejoin="round"
    >
      <path d="M14 4h6v6" />
      <path d="M20 4 10 14" />
      <path d="M19 13v6a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1h6" />
    </svg>
    """
  end

  defp merged_on(nil), do: ""
  defp merged_on(dt), do: "Merged on " <> Calendar.strftime(dt, "%Y-%m-%d %H:%M")
end

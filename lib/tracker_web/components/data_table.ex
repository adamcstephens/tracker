defmodule TrackerWeb.DataTable do
  @moduledoc """
  Pagination controls for paged lists.

  Emits `prev-page` and `next-page` events for the parent LiveView to handle,
  or renders links when `prev_path`/`next_path` are given.
  """
  use Phoenix.Component

  @doc """
  Renders pagination controls with prev/next buttons and page indicator.

  Emits `prev-page` and `next-page` events for the parent LiveView to handle.

  ## Examples

      <DataTable.pagination
        total_pages={@total_pages}
        current_page={@current_page}
        has_prev_page?={@has_prev_page?}
        has_next_page?={@has_next_page?}
      />
  """
  attr :total_pages, :integer,
    required: true,
    doc: "total page count, or nil when the data was fetched without a count"

  attr :current_page, :integer, required: true
  attr :has_prev_page?, :boolean, default: false
  attr :has_next_page?, :boolean, default: false

  attr :prev_path, :string,
    default: nil,
    doc:
      "URL for the previous page (no-JS fallback). When set, renders an <a> instead of a button."

  attr :next_path, :string,
    default: nil,
    doc: "URL for the next page (no-JS fallback). When set, renders an <a> instead of a button."

  def pagination(assigns) do
    ~H"""
    <nav
      :if={show_pagination?(@total_pages, @has_prev_page?, @has_next_page?)}
      style="display: flex; align-items: center; justify-content: center; gap: 0.5rem; margin-top: 1rem;"
    >
      <.link
        :if={@prev_path && @has_prev_page?}
        patch={@prev_path}
        role="button"
        class="outline secondary pagination-button"
      >
        &larr;
      </.link>
      <span
        :if={@prev_path && !@has_prev_page?}
        role="button"
        aria-disabled="true"
        class="outline secondary pagination-button"
      >
        &larr;
      </span>
      <button
        :if={!@prev_path}
        class="outline secondary pagination-button"
        phx-click="prev-page"
        disabled={!@has_prev_page?}
      >
        &larr;
      </button>
      <small :if={@total_pages}>
        Page {@current_page} of {@total_pages}
      </small>
      <small :if={is_nil(@total_pages)}>
        Page {@current_page}
      </small>
      <.link
        :if={@next_path && @has_next_page?}
        patch={@next_path}
        role="button"
        class="outline secondary pagination-button"
      >
        &rarr;
      </.link>
      <span
        :if={@next_path && !@has_next_page?}
        role="button"
        aria-disabled="true"
        class="outline secondary pagination-button"
      >
        &rarr;
      </span>
      <button
        :if={!@next_path}
        class="outline secondary pagination-button"
        phx-click="next-page"
        disabled={!@has_next_page?}
      >
        &rarr;
      </button>
    </nav>
    """
  end

  defp show_pagination?(nil, has_prev_page?, has_next_page?), do: has_prev_page? or has_next_page?
  defp show_pagination?(total_pages, _has_prev_page?, _has_next_page?), do: total_pages > 1
end

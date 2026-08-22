defmodule TrackerWeb.Pagination do
  @moduledoc """
  Pagination controls for paged lists.

  Renders prev/next links to `prev_path`/`next_path`, anchored at the list
  they page through.
  """
  use TrackerWeb, :html

  @doc """
  Renders pagination controls with prev/next links and a page indicator.

  ## Examples

      <Pagination.controls
        total_pages={@total_pages}
        current_page={@current_page}
        has_prev_page?={@has_prev_page?}
        has_next_page?={@has_next_page?}
        prev_path={~p"/packages?page=1"}
        next_path={~p"/packages?page=3"}
        anchor="packages"
      />
  """
  attr :total_pages, :integer,
    required: true,
    doc: "total page count, or nil when the data was fetched without a count"

  attr :current_page, :integer, required: true
  attr :has_prev_page?, :boolean, default: false
  attr :has_next_page?, :boolean, default: false
  attr :prev_path, :string, required: true, doc: "URL for the previous page"
  attr :next_path, :string, required: true, doc: "URL for the next page"

  attr :anchor, :string,
    required: true,
    doc:
      "DOM id of the list being paged. The fragment lands a full page load at the top of the list; the hook does the same for a LiveView patch."

  def controls(assigns) do
    assigns =
      assigns
      |> assign(:prev_path, anchored(assigns.prev_path, assigns.anchor))
      |> assign(:next_path, anchored(assigns.next_path, assigns.anchor))

    ~H"""
    <nav
      :if={show_pagination?(@total_pages, @has_prev_page?, @has_next_page?)}
      id={"pagination-#{@anchor}"}
      phx-hook="PageAnchor"
      data-anchor={@anchor}
      data-page={@current_page}
      style="display: flex; align-items: center; justify-content: center; gap: 0.5rem; margin-top: 1rem;"
    >
      <.link
        :if={@has_prev_page?}
        patch={@prev_path}
        role="button"
        class="outline secondary pagination-button"
      >
        &larr;
      </.link>
      <span
        :if={!@has_prev_page?}
        role="button"
        aria-disabled="true"
        class="outline secondary pagination-button"
      >
        &larr;
      </span>
      <small :if={@total_pages}>
        Page {@current_page} of {@total_pages}
      </small>
      <small :if={is_nil(@total_pages)}>
        Page {@current_page}
      </small>
      <.link
        :if={@has_next_page?}
        patch={@next_path}
        role="button"
        class="outline secondary pagination-button"
      >
        &rarr;
      </.link>
      <span
        :if={!@has_next_page?}
        role="button"
        aria-disabled="true"
        class="outline secondary pagination-button"
      >
        &rarr;
      </span>
    </nav>
    """
  end

  defp anchored(path, anchor), do: path <> "#" <> anchor

  defp show_pagination?(nil, has_prev_page?, has_next_page?), do: has_prev_page? or has_next_page?
  defp show_pagination?(total_pages, _has_prev_page?, _has_next_page?), do: total_pages > 1
end

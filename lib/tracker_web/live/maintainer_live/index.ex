defmodule TrackerWeb.MaintainerLive.Index do
  use TrackerWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Maintainers
    </.header>

    <form phx-change="search" phx-submit="search" id="maintainer-search" phx-hook="UpdateURL">
      <input
        type="search"
        name="search"
        value={@search}
        placeholder="Search maintainers..."
        phx-debounce="300"
      />
    </form>

    <.table
      id="maintainers"
      rows={@streams.maintainers}
      row_click={fn {_id, m} -> JS.navigate(~p"/maintainers/#{m.github}") end}
    >
      <:col :let={{_id, m}} label="Name">{m.name || m.github}</:col>
      <:col :let={{_id, m}} label="GitHub">{m.github}</:col>

      <:action :let={{_id, m}}>
        <div class="sr-only">
          <.link navigate={~p"/maintainers/#{m.github}"}>Show</.link>
        </div>
      </:action>
    </.table>

    <nav style="display: flex; align-items: center; justify-content: center; gap: 0.5rem; margin-top: 1rem;">
      <.button
        class="outline secondary"
        style="padding: 0.25rem 0.75rem; font-size: 0.875rem;"
        phx-click="prev-page"
        disabled={!@has_prev_page?}
      >
        &larr;
      </.button>
      <small :if={@total_pages > 0}>
        Page {@current_page} of {@total_pages}
      </small>
      <.button
        class="outline secondary"
        style="padding: 0.25rem 0.75rem; font-size: 0.875rem;"
        phx-click="next-page"
        disabled={!@has_next_page?}
      >
        &rarr;
      </.button>
    </nav>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_new(socket, :current_user, fn -> nil end)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    search = Map.get(params, "search", "")
    page = params |> Map.get("page", "1") |> String.to_integer() |> max(1)
    offset = (page - 1) * 15

    socket = assign(socket, :page_title, "Maintainers")

    socket =
      if socket.assigns[:search] == search and socket.assigns[:offset] == offset do
        socket
      else
        socket
        |> assign(:search, search)
        |> assign(:offset, offset)
        |> load_maintainers()
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    socket =
      socket
      |> assign(:search, search)
      |> assign(:offset, 0)
      |> load_maintainers()
      |> push_event("update-url", %{path: maintainers_path(search, 1)})

    {:noreply, socket}
  end

  @impl true
  def handle_event("next-page", _params, socket) do
    {:noreply,
     push_patch(socket,
       to: maintainers_path(socket.assigns.search, socket.assigns.current_page + 1)
     )}
  end

  @impl true
  def handle_event("prev-page", _params, socket) do
    {:noreply,
     push_patch(socket,
       to: maintainers_path(socket.assigns.search, max(socket.assigns.current_page - 1, 1))
     )}
  end

  defp maintainers_path(search, page) do
    params =
      %{}
      |> then(fn p -> if search != "", do: Map.put(p, :search, search), else: p end)
      |> then(fn p -> if page > 1, do: Map.put(p, :page, page), else: p end)

    case URI.encode_query(params) do
      "" -> "/maintainers"
      qs -> "/maintainers?#{qs}"
    end
  end

  defp load_maintainers(socket) do
    page =
      Tracker.Nixpkgs.Maintainer
      |> Ash.Query.for_read(:list, %{search: socket.assigns.search})
      |> Ash.read!(page: [offset: socket.assigns.offset, count: true])

    total_pages = ceil(page.count / 15)
    current_page = div(socket.assigns.offset, 15) + 1

    socket
    |> stream(:maintainers, page.results, reset: true)
    |> assign(:has_prev_page?, socket.assigns.offset > 0)
    |> assign(:has_next_page?, page.more?)
    |> assign(:total_pages, total_pages)
    |> assign(:current_page, current_page)
  end
end

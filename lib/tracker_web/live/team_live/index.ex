defmodule TrackerWeb.TeamLive.Index do
  use TrackerWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Teams
    </.header>

    <form phx-change="search" phx-submit="search" id="team-search" phx-hook="UpdateURL">
      <input
        type="search"
        name="search"
        value={@search}
        placeholder="Search teams..."
        phx-debounce="300"
      />
    </form>

    <.table
      id="teams"
      rows={@streams.teams}
    >
      <:col :let={{_id, t}} label="Name">
        <.link navigate={~p"/teams/#{t.short_name}"}>{t.short_name}</.link>
      </:col>
      <:col :let={{_id, t}} label="Scope">{t.scope}</:col>
    </.table>

    <nav
      :if={@total_pages > 1}
      style="display: flex; align-items: center; justify-content: center; gap: 0.5rem; margin-top: 1rem;"
    >
      <.button
        class="outline secondary"
        style="padding: 0.25rem 0.75rem; font-size: 0.875rem;"
        phx-click="prev-page"
        disabled={!@has_prev_page?}
      >
        &larr;
      </.button>
      <small>
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

    result =
      Tracker.Nixpkgs.Team.list!(search,
        page: [offset: offset, count: true, limit: 15]
      )

    total_pages = ceil(result.count / 15)

    {:noreply,
     socket
     |> assign(:page_title, "Teams")
     |> assign(:search, search)
     |> stream(:teams, result.results, reset: true)
     |> assign(:has_prev_page?, offset > 0)
     |> assign(:has_next_page?, result.more?)
     |> assign(:total_pages, total_pages)
     |> assign(:current_page, div(offset, 15) + 1)}
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    result =
      Tracker.Nixpkgs.Team.list!(search,
        page: [offset: 0, count: true, limit: 15]
      )

    total_pages = ceil(result.count / 15)

    socket =
      socket
      |> assign(:search, search)
      |> stream(:teams, result.results, reset: true)
      |> assign(:has_prev_page?, false)
      |> assign(:has_next_page?, result.more?)
      |> assign(:total_pages, total_pages)
      |> assign(:current_page, 1)
      |> push_event("update-url", %{path: teams_path(search, 1)})

    {:noreply, socket}
  end

  @impl true
  def handle_event("next-page", _params, socket) do
    {:noreply,
     push_patch(socket,
       to: teams_path(socket.assigns.search, socket.assigns.current_page + 1)
     )}
  end

  @impl true
  def handle_event("prev-page", _params, socket) do
    {:noreply,
     push_patch(socket,
       to: teams_path(socket.assigns.search, max(socket.assigns.current_page - 1, 1))
     )}
  end

  defp teams_path(search, page) do
    params =
      %{}
      |> then(fn p -> if search != "", do: Map.put(p, :search, search), else: p end)
      |> then(fn p -> if page > 1, do: Map.put(p, :page, page), else: p end)

    case URI.encode_query(params) do
      "" -> "/teams"
      qs -> "/teams?#{qs}"
    end
  end
end

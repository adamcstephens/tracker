defmodule TrackerWeb.TeamLive.Index do
  use TrackerWeb, :live_view

  alias TrackerWeb.DataTable
  alias TrackerWeb.TableParams

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
        value={@table_params.search}
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

    <DataTable.pagination
      total_pages={@total_pages}
      current_page={@current_page}
      has_prev_page?={@has_prev_page?}
      has_next_page?={@has_next_page?}
    />
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_new(socket, :current_user, fn -> nil end)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    tp = TableParams.from_params(params)

    result =
      Tracker.Nixpkgs.Team.list!(tp.search,
        page: [offset: tp.offset, count: true, limit: tp.page_size]
      )

    pagination = TableParams.apply_pagination(tp, result, :teams)

    {:noreply,
     socket
     |> assign(:page_title, "Teams")
     |> assign(:table_params, tp)
     |> stream(:teams, pagination.stream_results, reset: true)
     |> assign(:has_prev_page?, pagination.has_prev_page?)
     |> assign(:has_next_page?, pagination.has_next_page?)
     |> assign(:total_pages, pagination.total_pages)
     |> assign(:current_page, pagination.current_page)}
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    tp = %{socket.assigns.table_params | search: search, page: 1, offset: 0}

    result =
      Tracker.Nixpkgs.Team.list!(tp.search,
        page: [offset: tp.offset, count: true, limit: tp.page_size]
      )

    pagination = TableParams.apply_pagination(tp, result, :teams)

    socket =
      socket
      |> assign(:table_params, tp)
      |> stream(:teams, pagination.stream_results, reset: true)
      |> assign(:has_prev_page?, pagination.has_prev_page?)
      |> assign(:has_next_page?, pagination.has_next_page?)
      |> assign(:total_pages, pagination.total_pages)
      |> assign(:current_page, pagination.current_page)
      |> push_event("update-url", %{path: TableParams.to_path(tp, "/teams")})

    {:noreply, socket}
  end

  @impl true
  def handle_event("next-page", _params, socket) do
    tp = socket.assigns.table_params
    {:noreply, push_patch(socket, to: TableParams.to_path(%{tp | page: tp.page + 1}, "/teams"))}
  end

  @impl true
  def handle_event("prev-page", _params, socket) do
    tp = socket.assigns.table_params

    {:noreply,
     push_patch(socket, to: TableParams.to_path(%{tp | page: max(tp.page - 1, 1)}, "/teams"))}
  end

  @impl true
  def handle_info({:set_lens, channel_name, rev}, socket) do
    {:noreply, TrackerWeb.LensHandlers.handle_lens_change(socket, channel_name, rev)}
  end
end

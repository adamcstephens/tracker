defmodule TrackerWeb.TeamLive.Index do
  use TrackerWeb, :live_view

  alias TrackerWeb.PageSearch
  alias TrackerWeb.Pagination
  alias TrackerWeb.RowList
  alias TrackerWeb.TableParams

  @impl true
  def render(assigns) do
    ~H"""
    <RowList.row_list id="teams" phx-update="stream" reserve_sublabel>
      <RowList.row
        :for={{dom_id, t} <- @streams.teams}
        id={dom_id}
        mode={:link}
        navigate={~p"/teams/#{t.short_name}"}
      >
        <:label>{t.short_name}</:label>
        <:sublabel :if={t.scope}>{t.scope}</:sublabel>
        <:actions><span class="arrow" aria-hidden="true">→</span></:actions>
      </RowList.row>
    </RowList.row_list>

    <Pagination.controls
      total_pages={@total_pages}
      current_page={@current_page}
      has_prev_page?={@has_prev_page?}
      has_next_page?={@has_next_page?}
      prev_path={TableParams.page_path(@table_params, @current_page - 1, "/teams")}
      next_path={TableParams.page_path(@table_params, @current_page + 1, "/teams")}
      anchor="teams"
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

    {:noreply,
     socket
     |> assign(:page_title, "Teams")
     |> assign(:table_params, tp)
     |> assign(:page_search, %PageSearch{
       action: "/teams",
       value: tp.search,
       hidden: TableParams.to_hidden_inputs(tp)
     })
     |> load_teams()}
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    tp = %{socket.assigns.table_params | search: search, page: 1, offset: 0}

    socket =
      socket
      |> assign(:table_params, tp)
      |> update(:page_search, fn ps ->
        %{ps | value: tp.search, hidden: TableParams.to_hidden_inputs(tp)}
      end)
      |> load_teams()
      |> push_event("update-url", %{path: TableParams.to_path(tp, "/teams")})

    {:noreply, socket}
  end

  defp load_teams(socket) do
    tp = socket.assigns.table_params

    result =
      Tracker.Nixpkgs.Team.list!(tp.search,
        page: [offset: tp.offset, count: true, limit: tp.page_size]
      )

    pagination = TableParams.apply_pagination(tp, result, :teams)

    socket
    |> stream(:teams, pagination.stream_results, reset: true)
    |> assign(:has_prev_page?, pagination.has_prev_page?)
    |> assign(:has_next_page?, pagination.has_next_page?)
    |> assign(:total_pages, pagination.total_pages)
    |> assign(:current_page, pagination.current_page)
  end
end

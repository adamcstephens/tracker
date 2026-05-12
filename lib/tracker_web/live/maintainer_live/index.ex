defmodule TrackerWeb.MaintainerLive.Index do
  use TrackerWeb, :live_view

  alias TrackerWeb.DataTable
  alias TrackerWeb.PageSearch
  alias TrackerWeb.TableParams

  @impl true
  def render(assigns) do
    ~H"""
    <.table
      id="maintainers"
      rows={@streams.maintainers}
    >
      <:col :let={{_id, m}} label="GitHub">
        <.link navigate={~p"/maintainers/#{m.github}"}>{m.github}</.link>
      </:col>
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

    socket =
      socket
      |> assign(:page_title, "Maintainers")
      |> assign(:page_search, %PageSearch{
        action: "/maintainers",
        value: tp.search,
        hidden: TableParams.to_hidden_inputs(tp)
      })

    socket =
      if TableParams.changed?(socket.assigns[:table_params], tp) do
        socket |> assign(:table_params, tp) |> load_maintainers()
      else
        socket
      end

    {:noreply, socket}
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
      |> load_maintainers()
      |> push_event("update-url", %{path: TableParams.to_path(tp, "/maintainers")})

    {:noreply, socket}
  end

  @impl true
  def handle_event("next-page", _params, socket) do
    tp = socket.assigns.table_params

    {:noreply,
     push_patch(socket, to: TableParams.to_path(%{tp | page: tp.page + 1}, "/maintainers"))}
  end

  @impl true
  def handle_event("prev-page", _params, socket) do
    tp = socket.assigns.table_params

    {:noreply,
     push_patch(socket,
       to: TableParams.to_path(%{tp | page: max(tp.page - 1, 1)}, "/maintainers")
     )}
  end

  defp load_maintainers(socket) do
    tp = socket.assigns.table_params

    page =
      Tracker.Nixpkgs.Maintainer.list!(tp.search, page: [offset: tp.offset, count: true])

    pagination = TableParams.apply_pagination(tp, page, :maintainers)

    socket
    |> stream(:maintainers, pagination.stream_results, reset: true)
    |> assign(:has_prev_page?, pagination.has_prev_page?)
    |> assign(:has_next_page?, pagination.has_next_page?)
    |> assign(:total_pages, pagination.total_pages)
    |> assign(:current_page, pagination.current_page)
  end

  @impl true
  def handle_info({:set_lens, channel_name, rev}, socket) do
    socket = TrackerWeb.LensHandlers.handle_lens_change(socket, channel_name, rev)
    {:noreply, load_maintainers(socket)}
  end
end

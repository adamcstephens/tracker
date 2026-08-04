defmodule TrackerWeb.PackageLive.Index do
  use TrackerWeb, :live_view

  alias TrackerWeb.PageSearch
  alias TrackerWeb.Pagination
  alias TrackerWeb.RowList
  alias TrackerWeb.TableParams

  @impl true
  def render(assigns) do
    ~H"""
    <RowList.row_list id="packages" phx-update="stream" stacked>
      <RowList.row
        :for={{dom_id, package} <- @streams.packages}
        id={dom_id}
        mode={:link}
        navigate={~p"/packages/#{package.attribute}"}
      >
        <:label>{package.attribute}</:label>
        <:sublabel :if={package.description}>{package.description}</:sublabel>
        <:meta>{format_datetime(package.inserted_at)}</:meta>
      </RowList.row>
    </RowList.row_list>

    <Pagination.controls
      total_pages={@total_pages}
      current_page={@current_page}
      has_prev_page?={@has_prev_page?}
      has_next_page?={@has_next_page?}
      prev_path={TableParams.page_path(@table_params, @current_page - 1, "/packages")}
      next_path={TableParams.page_path(@table_params, @current_page + 1, "/packages")}
    />
    """
  end

  defp format_datetime(nil), do: "-"
  defp format_datetime(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_new(socket, :current_user, fn -> nil end)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    tp = TableParams.from_params(params)

    socket =
      socket
      |> assign(:page_title, "Packages")
      |> assign(:table_params, tp)
      |> assign(:page_search, %PageSearch{
        action: "/packages",
        value: tp.search,
        hidden: TableParams.to_hidden_inputs(tp)
      })
      |> load_packages()

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
      |> load_packages()
      |> push_event("update-url", %{path: TableParams.to_path(tp, "/packages")})

    {:noreply, socket}
  end

  @impl true
  def handle_event("next-page", _params, socket) do
    tp = socket.assigns.table_params

    {:noreply,
     push_patch(socket, to: TableParams.to_path(%{tp | page: tp.page + 1}, "/packages"))}
  end

  @impl true
  def handle_event("prev-page", _params, socket) do
    tp = socket.assigns.table_params

    {:noreply,
     push_patch(socket, to: TableParams.to_path(%{tp | page: max(tp.page - 1, 1)}, "/packages"))}
  end

  defp load_packages(socket) do
    tp = socket.assigns.table_params
    channel_id = TrackerWeb.Lens.channel_id(socket.assigns.lens)

    page =
      Tracker.Nixpkgs.Package.list!(tp.search, channel_id,
        actor: socket.assigns[:current_user],
        query: [sort: [inserted_at: :desc]],
        page: [offset: tp.offset]
      )

    pagination = TableParams.apply_pagination(tp, page, :packages)
    rows = TrackerWeb.PackageRows.with_current_descriptions(pagination.stream_results, channel_id)

    socket
    |> stream(:packages, rows, reset: true)
    |> assign(:has_prev_page?, pagination.has_prev_page?)
    |> assign(:has_next_page?, pagination.has_next_page?)
    |> assign(:total_pages, pagination.total_pages)
    |> assign(:current_page, pagination.current_page)
  end

  @impl true
  def handle_info({:set_lens, channel_name, rev}, socket) do
    socket = TrackerWeb.LensHandlers.handle_lens_change(socket, channel_name, rev)
    {:noreply, load_packages(socket)}
  end
end

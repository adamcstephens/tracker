defmodule TrackerWeb.PackageLive.Index do
  use TrackerWeb, :live_view

  alias TrackerWeb.DataTable
  alias TrackerWeb.PageSearch
  alias TrackerWeb.TableParams

  @table_opts [
    allowed_sorts: ~w(attribute inserted_at)a,
    default_sort: :inserted_at,
    default_sort_dir: :desc
  ]

  @impl true
  def render(assigns) do
    ~H"""
    <DataTable.data_table
      id="packages"
      rows={@streams.packages}
      table_params={@table_params}
      base_path="/packages"
      total_pages={@total_pages}
      current_page={@current_page}
      has_prev_page?={@has_prev_page?}
      has_next_page?={@has_next_page?}
    >
      <:col :let={{_id, package}} field={:attribute} label="Attribute" sortable>
        <.link navigate={~p"/packages/#{package.attribute}"}>{package.attribute}</.link>
      </:col>
      <:col :let={{_id, package}} label="Description">
        <span style="display: block; max-width: 30ch; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
          {package.description}
        </span>
      </:col>
      <:col :let={{_id, package}} field={:inserted_at} label="Discovered" sortable>
        {format_datetime(package.inserted_at)}
      </:col>
    </DataTable.data_table>
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
    tp = TableParams.from_params(params, @table_opts)

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
  def handle_event("sort", %{"field" => field}, socket) do
    tp = socket.assigns.table_params
    new_sort_by = TableParams.from_params(%{"sort_by" => field}, @table_opts).sort_by

    new_sort_dir =
      if tp.sort_by == new_sort_by, do: TableParams.toggle_dir(tp.sort_dir), else: :asc

    new_tp = %{tp | sort_by: new_sort_by, sort_dir: new_sort_dir, page: 1, offset: 0}

    {:noreply, push_patch(socket, to: TableParams.to_path(new_tp, "/packages"))}
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
        query: [sort: [{tp.sort_by, tp.sort_dir}]],
        page: [offset: tp.offset]
      )

    pagination = TableParams.apply_pagination(tp, page, :packages)

    socket
    |> stream(:packages, pagination.stream_results, reset: true)
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

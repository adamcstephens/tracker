defmodule TrackerWeb.PackageLive.Index do
  use TrackerWeb, :live_view

  alias TrackerWeb.TableParams

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Listing Packages
    </.header>

    <form phx-change="search" phx-submit="search" id="package-search" phx-hook="UpdateURL">
      <input
        type="search"
        name="search"
        value={@table_params.search}
        placeholder="Search packages..."
        phx-debounce="300"
      />
    </form>

    <.table
      id="packages"
      rows={@streams.packages}
    >
      <:col :let={{_id, package}} label="Attribute">
        <.link navigate={~p"/packages/#{package.attribute}"}>{package.attribute}</.link>
      </:col>
      <:col :let={{_id, package}} label="Description">
        <span style="display: block; max-width: 30ch; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
          {package.description}
        </span>
      </:col>
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
    tp = TableParams.from_params(params)

    socket = assign(socket, :page_title, "Listing Packages")

    socket =
      if TableParams.changed?(socket.assigns[:table_params], tp) do
        socket |> assign(:table_params, tp) |> load_packages()
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

    page =
      Tracker.Nixpkgs.Package.list!(tp.search,
        actor: socket.assigns[:current_user],
        page: [offset: tp.offset, count: true]
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
    {:noreply, TrackerWeb.LensHandlers.handle_lens_change(socket, channel_name, rev)}
  end
end

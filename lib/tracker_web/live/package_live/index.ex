defmodule TrackerWeb.PackageLive.Index do
  use TrackerWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Listing Packages
    </.header>

    <.table
      id="packages"
      rows={@streams.packages}
      row_click={fn {_id, package} -> JS.navigate(~p"/packages/#{package}") end}
    >
      <:col :let={{_id, package}} label="Id">{package.id}</:col>

      <:col :let={{_id, package}} label="Attribute">{package.attribute}</:col>

      <:action :let={{_id, package}}>
        <div class="sr-only">
          <.link navigate={~p"/packages/#{package}"}>Show</.link>
        </div>
      </:action>
    </.table>

    <div class="flex items-center justify-between mt-4">
      <.button :if={@has_prev_page?} phx-click="prev-page">
        Previous
      </.button>
      <span :if={@total_pages > 0} class="text-sm text-zinc-600">
        Page {@current_page} of {@total_pages}
      </span>
      <.button :if={@has_next_page?} phx-click="next-page">
        Next
      </.button>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign_new(:current_user, fn -> nil end)
      |> assign(:offset, 0)
      |> load_packages()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  @impl true
  def handle_event("next-page", _params, socket) do
    offset = socket.assigns.offset + 15
    {:noreply, socket |> assign(:offset, offset) |> load_packages()}
  end

  @impl true
  def handle_event("prev-page", _params, socket) do
    offset = max(socket.assigns.offset - 15, 0)
    {:noreply, socket |> assign(:offset, offset) |> load_packages()}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Listing Packages")
  end

  defp load_packages(socket) do
    page =
      Tracker.Nixpkgs.Package
      |> Ash.read!(
        action: :list,
        actor: socket.assigns[:current_user],
        page: [offset: socket.assigns.offset, count: true]
      )

    total_pages = ceil(page.count / 15)
    current_page = div(socket.assigns.offset, 15) + 1

    socket
    |> stream(:packages, page.results, reset: true)
    |> assign(:has_prev_page?, socket.assigns.offset > 0)
    |> assign(:has_next_page?, page.more?)
    |> assign(:total_pages, total_pages)
    |> assign(:current_page, current_page)
  end
end

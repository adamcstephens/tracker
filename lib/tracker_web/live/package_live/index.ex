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
      <:col :let={{_id, package}} label="Attribute">{package.attribute}</:col>

      <:action :let={{_id, package}}>
        <div class="sr-only">
          <.link navigate={~p"/packages/#{package}"}>Show</.link>
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

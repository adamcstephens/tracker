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
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> stream(
       :packages,
       Ash.read!(Tracker.Nixpkgs.Package, actor: socket.assigns[:current_user], page: [limit: 10]).results
     )
     |> assign_new(:current_user, fn -> nil end)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Listing Packages")
  end
end

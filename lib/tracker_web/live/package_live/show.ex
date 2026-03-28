defmodule TrackerWeb.PackageLive.Show do
  use TrackerWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Package {@package.id}
      <:subtitle>This is a package record from your database.</:subtitle>
    </.header>

    <.list>
      <:item title="Id">{@package.id}</:item>

      <:item title="Attribute">{@package.attribute}</:item>
    </.list>

    <.back navigate={~p"/packages"}>Back to packages</.back>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id}, _, socket) do
    {:noreply,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(
       :package,
       Ash.get!(Tracker.Nixpkgs.Package, id)
     )}
  end

  defp page_title(:show), do: "Show Package"
  defp page_title(:edit), do: "Edit Package"
end

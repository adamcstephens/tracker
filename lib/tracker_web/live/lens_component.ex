defmodule TrackerWeb.LensComponent do
  @moduledoc """
  LiveComponent for the sitewide channel lens selector in the nav bar.

  Renders a divided-pill selector: a `Channel` label, the channel `<select>`
  (which acts as the dropdown trigger), and an optional read-only revision
  display when the lens is pinned to a specific revision.

  Progressive enhancement: wraps the channel `<select>` in a form that POSTs
  to `/lens` for no-JS fallback. With JS, `phx-change` sends events to the
  parent LiveView.
  """

  use TrackerWeb, :live_component

  alias Tracker.Nixpkgs.Channel

  @impl true
  def update(assigns, socket) do
    channels =
      if connected?(socket) do
        Channel.nixos_channels!()
      else
        socket.assigns[:channels] || Channel.nixos_channels!()
      end

    {:ok,
     socket
     |> assign(:lens, assigns.lens)
     |> assign(:channels, channels)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="lens" class="lens" phx-hook="LensCookie">
      <form
        :if={@lens != nil}
        method="post"
        action="/lens"
        phx-change="set_lens"
        phx-target={@myself}
        class="lens__form"
      >
        <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
        <span class="lens-label">Channel</span>
        <select
          name="channel"
          aria-label="Channel"
          class="lens__select"
          disabled={@lens.disabled?}
        >
          <option value="all" selected={@lens.all?}>All channels</option>
          <option
            :for={ch <- @channels}
            value={ch.name}
            selected={!@lens.all? && ch.name == @lens.channel.name}
          >
            {ch.name}
          </option>
        </select>
        <span :if={short_rev(@lens)} class="lens-rev">@{short_rev(@lens)}</span>
      </form>
    </div>
    """
  end

  @impl true
  def handle_event("set_lens", %{"channel" => channel_name}, socket) do
    send(self(), {:set_lens, channel_name, ""})

    {:noreply, socket}
  end

  defp short_rev(%{revision: nil}), do: nil
  defp short_rev(%{revision: rev}), do: String.slice(rev.revision, 0, 7)
end

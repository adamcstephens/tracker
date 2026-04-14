defmodule TrackerWeb.LensComponent do
  @moduledoc """
  LiveComponent for the sitewide channel lens selector in the nav bar.

  Renders a channel dropdown (always visible) and an optional revision
  input (behind a toggle). When `disabled?` is true, controls are greyed out.

  Progressive enhancement: wraps controls in a form that POSTs to
  `/lens` for no-JS fallback. With JS, `phx-change` sends events to
  the parent LiveView.
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
     |> assign(:channels, channels)
     |> assign(:show_rev, assigns.lens != nil && assigns.lens.revision != nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="lens" phx-hook="LensCookie">
      <form
        :if={@lens != nil}
        method="post"
        action="/lens"
        phx-change="set_lens"
        phx-target={@myself}
      >
        <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
        <fieldset role="group" style="margin-bottom: 0;">
          <select
            name="channel"
            aria-label="Channel"
            disabled={@lens.disabled?}
          >
            <option value="all" selected={@lens.all?}>
              All channels
            </option>
            <option
              :for={ch <- @channels}
              value={ch.name}
              selected={!@lens.all? && ch.name == @lens.channel.name}
            >
              {ch.name}
            </option>
          </select>
          <button
            :if={!@show_rev}
            type="button"
            class="outline secondary"
            phx-click="toggle_rev"
            phx-target={@myself}
            disabled={@lens.disabled?}
            style="white-space: nowrap;"
          >
            Rev
          </button>
          <input
            :if={@show_rev}
            type="text"
            name="rev"
            value={rev_display(@lens)}
            placeholder="latest"
            disabled={@lens.disabled?}
            phx-debounce="500"
          />
        </fieldset>
      </form>
    </div>
    """
  end

  @impl true
  def handle_event("toggle_rev", _params, socket) do
    {:noreply, assign(socket, :show_rev, !socket.assigns.show_rev)}
  end

  @impl true
  def handle_event("set_lens", %{"channel" => channel_name} = params, socket) do
    rev = Map.get(params, "rev", "")

    send(self(), {:set_lens, channel_name, rev})

    {:noreply, socket}
  end

  defp rev_display(%{revision: nil}), do: ""
  defp rev_display(%{revision: rev}), do: String.slice(rev.revision, 0, 7)
end

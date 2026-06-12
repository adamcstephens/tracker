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
  alias Tracker.Nixpkgs.ChannelRevision

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
     |> assign(:highlight, Map.get(assigns, :highlight, false))
     |> assign(:channels, channels)
     |> assign(:display_rev, display_rev(assigns.lens))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="lens" class={["lens", @highlight && "lens-attention"]} phx-hook="LensCookie">
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
        <span class="lens-channel-cell">
          <span class="lens-dot" aria-hidden="true"></span>
          <span class="lens-channel-name" aria-hidden="true">
            {if @lens.all?, do: "All channels", else: @lens.channel.name}
          </span>
          <%!-- Invisible overlay on the cell: the visible name above sizes
               the cell to the selected channel, while a native select sized
               to its widest option would leave dead space after it. --%>
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
        </span>
        <span :if={@display_rev} class="lens-rev">@{String.slice(@display_rev.revision, 0, 7)}</span>
        <button
          type="submit"
          class="lens__submit"
          aria-label="Set channel"
          disabled={@lens.disabled?}
        >
          <span class="lens__icon" aria-hidden="true"></span>
        </button>
      </form>
    </div>
    """
  end

  @impl true
  def handle_event("set_lens", %{"channel" => channel_name}, socket) do
    send(self(), {:set_lens, channel_name, ""})

    {:noreply, socket}
  end

  # The revision shown next to the channel: the pinned one when the lens
  # carries it, otherwise the channel's latest.
  defp display_rev(nil), do: nil
  defp display_rev(%{all?: true}), do: nil
  defp display_rev(%{revision: %ChannelRevision{} = rev}), do: rev

  defp display_rev(%{channel: channel}) do
    case ChannelRevision.latest_by_channel(channel.id) do
      {:ok, rev} -> rev
      _ -> nil
    end
  end
end

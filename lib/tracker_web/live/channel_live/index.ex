defmodule TrackerWeb.ChannelLive.Index do
  use TrackerWeb, :live_view

  require Ash.Query

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Channels
    </.header>

    <.table
      id="channels"
      rows={@streams.channels}
      row_click={fn {_id, channel} -> JS.navigate(~p"/channels/#{channel.name}") end}
    >
      <:col :let={{_id, channel}} label="Channel">{channel.name}</:col>
      <:col :let={{_id, channel}} label="Revisions">{channel.count}</:col>
      <:col :let={{_id, channel}} label="Latest Release">{format_date(channel.latest_release)}</:col>

      <:action :let={{_id, channel}}>
        <div class="sr-only">
          <.link navigate={~p"/channels/#{channel.name}"}>Show</.link>
        </div>
      </:action>
    </.table>
    """
  end

  defp format_date(nil), do: "-"
  defp format_date(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_new(socket, :current_user, fn -> nil end)}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    channels = load_channels()

    {:noreply,
     socket
     |> assign(:page_title, "Channels")
     |> stream(:channels, channels, reset: true)}
  end

  defp load_channels do
    Tracker.Nixpkgs.ChannelRevision
    |> Ash.read!()
    |> Enum.group_by(& &1.channel)
    |> Enum.map(fn {name, revisions} ->
      latest = revisions |> Enum.max_by(& &1.released_at, DateTime, fn -> nil end)

      %{
        id: name,
        name: name,
        count: length(revisions),
        latest_release: latest && latest.released_at
      }
    end)
    |> Enum.sort_by(& &1.name)
  end
end

defmodule TrackerWeb.ChannelLive.Index do
  use TrackerWeb, :live_view

  alias TrackerWeb.PageSearch
  alias TrackerWeb.RowList

  @impl true
  def render(assigns) do
    ~H"""
    <RowList.row_list id="channels" stacked>
      <RowList.row
        :for={channel <- @channels}
        mode={:link}
        navigate={~p"/channels/#{channel.name}"}
      >
        <:label>
          {channel.name}
          <.badge :if={channel.build_problem?} variant={:danger}>Build problem</.badge>
          <.badge :if={channel.status == :pre_release} variant={:warn}>Pre-release</.badge>
          <.badge :if={channel.status == :deprecated} variant={:warn}>Deprecated</.badge>
          <.badge :if={channel.status == :retired} variant={:neutral}>Retired</.badge>
        </:label>
        <:meta>
          <span>{channel.count} revisions</span>
          <span>{format_date(channel.latest_release)}</span>
        </:meta>
        <:actions>
          <span class="arrow" aria-hidden="true">→</span>
        </:actions>
      </RowList.row>
    </RowList.row_list>
    """
  end

  defp format_date(nil), do: "-"
  defp format_date(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Tracker.PubSub, "channels:hydra_status_updated")
      Phoenix.PubSub.subscribe(Tracker.PubSub, "channel_revisions:any:created")
      Phoenix.PubSub.subscribe(Tracker.PubSub, "channel_revisions:any:completed")
    end

    {:ok, assign_new(socket, :current_user, fn -> nil end)}
  end

  @impl true
  def handle_info(
        %Ash.Notifier.Notification{resource: Tracker.Nixpkgs.Channel, data: channel},
        socket
      ) do
    {:noreply, replace_channel(socket, channel)}
  end

  def handle_info(
        %Ash.Notifier.Notification{
          resource: Tracker.Nixpkgs.ChannelRevision,
          data: %{channel_id: channel_id}
        },
        socket
      ) do
    case Ash.get(Tracker.Nixpkgs.Channel, channel_id, load: [:build_problem?]) do
      {:ok, channel} -> {:noreply, replace_channel(socket, channel)}
      _ -> {:noreply, socket}
    end
  end

  def handle_info({:set_lens, channel_name, rev}, socket) do
    {:noreply, TrackerWeb.LensHandlers.handle_lens_change(socket, channel_name, rev)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    lens = socket.assigns.lens && %{socket.assigns.lens | disabled?: true}

    {:noreply,
     socket
     |> assign(:page_title, "Channels")
     |> assign(:lens, lens)
     |> assign(:page_search, %PageSearch{
       mode: :inert,
       value: Map.get(params, "search", "")
     })
     |> assign(:channels, load_channels())}
  end

  defp load_channels do
    Tracker.Nixpkgs.Channel.read!(load: [:build_problem?])
    |> Enum.map(&channel_row/1)
    |> sort_channels()
  end

  defp replace_channel(socket, channel) do
    row = channel_row(channel)

    channels =
      socket.assigns.channels
      |> Enum.reject(&(&1.name == row.name))
      |> then(&[row | &1])
      |> sort_channels()

    assign(socket, :channels, channels)
  end

  defp channel_row(channel) do
    revisions = Tracker.Nixpkgs.ChannelRevision.by_channel!(channel.id)
    latest = Enum.max_by(revisions, & &1.released_at, DateTime, fn -> nil end)

    %{
      name: channel.name,
      count: length(revisions),
      latest_release: latest && latest.released_at,
      build_problem?: channel.build_problem?,
      status: channel.status
    }
  end

  defp sort_channels(channels),
    do:
      Enum.sort_by(
        channels,
        &(&1.latest_release || ~U[0000-01-01 00:00:00Z]),
        {:desc, DateTime}
      )
end

defmodule TrackerWeb.ChannelLive.Index do
  use TrackerWeb, :live_view

  alias TrackerWeb.DataTable
  alias TrackerWeb.TableParams

  @table_opts [
    allowed_sorts: ~w(name count latest_release)a,
    default_sort: :latest_release,
    default_sort_dir: :desc
  ]

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Channels
    </.header>

    <DataTable.data_table
      id="channels"
      rows={@streams.channels}
      table_params={@table_params}
      base_path="/channels"
    >
      <:col :let={{_id, channel}} field={:name} label="Channel" sortable>
        <.link navigate={~p"/channels/#{channel.name}"}>{channel.name}</.link>
      </:col>
      <:col :let={{_id, channel}} field={:count} label="Revisions" sortable>
        {channel.count}
      </:col>
      <:col :let={{_id, channel}} field={:latest_release} label="Latest Release" sortable>
        {format_date(channel.latest_release)}
      </:col>
    </DataTable.data_table>
    """
  end

  defp format_date(nil), do: "-"
  defp format_date(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_new(socket, :current_user, fn -> nil end)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    tp = TableParams.from_params(params, @table_opts)

    channels = load_channels(tp.sort_by, tp.sort_dir)

    lens = socket.assigns.lens && %{socket.assigns.lens | disabled?: true}

    {:noreply,
     socket
     |> assign(:page_title, "Channels")
     |> assign(:table_params, tp)
     |> assign(:lens, lens)
     |> stream(:channels, channels, reset: true)}
  end

  @impl true
  def handle_event("sort", %{"field" => field}, socket) do
    tp = socket.assigns.table_params
    new_sort_by = TableParams.from_params(%{"sort_by" => field}, @table_opts).sort_by

    new_sort_dir =
      if tp.sort_by == new_sort_by, do: TableParams.toggle_dir(tp.sort_dir), else: :asc

    new_tp = %{tp | sort_by: new_sort_by, sort_dir: new_sort_dir}

    {:noreply, push_patch(socket, to: TableParams.to_path(new_tp, "/channels"))}
  end

  defp load_channels(sort_by, sort_dir) do
    Tracker.Nixpkgs.Channel.read!()
    |> Enum.map(fn channel ->
      revisions = Tracker.Nixpkgs.ChannelRevision.by_channel!(channel.id)
      latest = revisions |> Enum.max_by(& &1.released_at, DateTime, fn -> nil end)

      %{
        id: channel.name,
        name: channel.name,
        count: length(revisions),
        latest_release: latest && latest.released_at
      }
    end)
    |> sort_channels(sort_by, sort_dir)
  end

  defp sort_channels(channels, :name, dir), do: sort_by_field(channels, & &1.name, dir)
  defp sort_channels(channels, :count, dir), do: sort_by_field(channels, & &1.count, dir)

  defp sort_channels(channels, :latest_release, dir),
    do: sort_by_field(channels, & &1.latest_release, dir)

  defp sort_by_field(channels, fun, :asc), do: Enum.sort_by(channels, fun, &<=/2)
  defp sort_by_field(channels, fun, :desc), do: Enum.sort_by(channels, fun, &>=/2)

  @impl true
  def handle_info({:set_lens, channel_name, rev}, socket) do
    {:noreply, TrackerWeb.LensHandlers.handle_lens_change(socket, channel_name, rev)}
  end
end

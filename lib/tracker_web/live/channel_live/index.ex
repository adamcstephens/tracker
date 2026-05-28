defmodule TrackerWeb.ChannelLive.Index do
  use TrackerWeb, :live_view

  alias TrackerWeb.DataTable
  alias TrackerWeb.PageSearch
  alias TrackerWeb.TableParams

  @table_opts [
    allowed_sorts: ~w(name count latest_release)a,
    default_sort: :latest_release,
    default_sort_dir: :desc
  ]

  @impl true
  def render(assigns) do
    ~H"""
    <DataTable.data_table
      id="channels"
      rows={@streams.channels}
      table_params={@table_params}
      base_path="/channels"
    >
      <:col :let={{_id, channel}} field={:name} label="Channel" sortable>
        <.link navigate={~p"/channels/#{channel.name}"}>{channel.name}</.link>
        <.link
          :if={channel.build_problem?}
          href={hydra_jobset_url(channel)}
          target="_blank"
          rel="noopener"
        >
          <.badge variant={:danger}>Build problem</.badge>
        </.link>
        <.badge :if={channel.status == :pre_release} variant={:warn}>Pre-release</.badge>
        <.badge :if={channel.status == :retired} variant={:neutral}>Retired</.badge>
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
    {:noreply, stream_insert(socket, :channels, channel_row(channel))}
  end

  def handle_info(
        %Ash.Notifier.Notification{
          resource: Tracker.Nixpkgs.ChannelRevision,
          data: %{channel_id: channel_id}
        },
        socket
      ) do
    case Ash.get(Tracker.Nixpkgs.Channel, channel_id, load: [:build_problem?]) do
      {:ok, channel} -> {:noreply, stream_insert(socket, :channels, channel_row(channel))}
      _ -> {:noreply, socket}
    end
  end

  def handle_info({:set_lens, channel_name, rev}, socket) do
    {:noreply, TrackerWeb.LensHandlers.handle_lens_change(socket, channel_name, rev)}
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
     |> assign(:page_search, %PageSearch{
       mode: :inert,
       value: Map.get(params, "search", "")
     })
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
    Tracker.Nixpkgs.Channel.read!(load: [:build_problem?])
    |> Enum.map(&channel_row/1)
    |> sort_channels(sort_by, sort_dir)
  end

  defp channel_row(channel) do
    revisions = Tracker.Nixpkgs.ChannelRevision.by_channel!(channel.id)
    latest = Enum.max_by(revisions, & &1.released_at, DateTime, fn -> nil end)

    %{
      id: channel.name,
      name: channel.name,
      count: length(revisions),
      latest_release: latest && latest.released_at,
      build_problem?: channel.build_problem?,
      hydra_project: channel.hydra_project,
      hydra_jobset: channel.hydra_jobset,
      status: channel.status
    }
  end

  defp hydra_jobset_url(%{hydra_project: project, hydra_jobset: jobset})
       when is_binary(project) and is_binary(jobset),
       do: "https://hydra.nixos.org/jobset/#{project}/#{jobset}"

  defp hydra_jobset_url(_), do: "https://hydra.nixos.org/"

  defp sort_channels(channels, :name, dir), do: sort_by_field(channels, & &1.name, dir)
  defp sort_channels(channels, :count, dir), do: sort_by_field(channels, & &1.count, dir)

  defp sort_channels(channels, :latest_release, dir),
    do: sort_by_field(channels, & &1.latest_release, dir)

  defp sort_by_field(channels, fun, :asc), do: Enum.sort_by(channels, fun, &<=/2)
  defp sort_by_field(channels, fun, :desc), do: Enum.sort_by(channels, fun, &>=/2)
end

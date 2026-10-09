defmodule TrackerWeb.ChannelLive.RevisionShow do
  use TrackerWeb, :live_view

  import TrackerWeb.ChannelLive.DiffSections

  alias Tracker.Nixpkgs.ChannelRevision
  alias TrackerWeb.ChannelLive.ComparisonState

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.revision_comparison {assigns} />
    """
  end

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign_new(:current_user, fn -> nil end)
     |> assign(:subscribed_channel_id, nil)}
  end

  @impl Phoenix.LiveView
  def handle_params(
        %{"path_channel" => channel_name, "revision" => rev_hash} = params,
        _url,
        socket
      ) do
    channel = Tracker.Nixpkgs.Channel.by_name!(channel_name)

    if connected?(socket) && socket.assigns.subscribed_channel_id != channel.id do
      if socket.assigns.subscribed_channel_id do
        Phoenix.PubSub.unsubscribe(
          Tracker.PubSub,
          "channel_revisions:#{socket.assigns.subscribed_channel_id}:completed"
        )
      end

      Phoenix.PubSub.subscribe(Tracker.PubSub, "channel_revisions:#{channel.id}:completed")
    end

    revision = ChannelRevision.find_by_channel_hash!(channel.id, rev_hash)

    {:noreply,
     socket
     |> assign(:subscribed_channel_id, channel.id)
     |> assign(:comparison_params, params)
     |> assign_revision_data(channel_name, revision, params)}
  end

  @impl Phoenix.LiveView
  def handle_event("search", %{"search" => search}, socket) do
    {:noreply, ComparisonState.search(socket, search)}
  end

  @impl Phoenix.LiveView
  def handle_info(
        %Ash.Notifier.Notification{resource: ChannelRevision, action: %{name: :record_result}},
        socket
      ) do
    revision =
      ChannelRevision.find_by_channel_hash!(
        socket.assigns.subscribed_channel_id,
        socket.assigns.revision.revision
      )

    {:noreply,
     assign_revision_data(
       socket,
       socket.assigns.channel,
       revision,
       socket.assigns.comparison_params
     )}
  end

  defp assign_revision_data(socket, channel_name, %ChannelRevision{} = revision, params) do
    previous_revision =
      if revision.previous_channel_revision_id do
        ChannelRevision.get_by_id!(revision.previous_channel_revision_id)
      end

    socket
    |> assign(:page_title, "#{channel_name} — #{String.slice(revision.revision, 0, 7)}")
    |> ComparisonState.load(channel_name, previous_revision, revision, params)
  end
end

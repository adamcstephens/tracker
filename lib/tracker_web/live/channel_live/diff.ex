defmodule TrackerWeb.ChannelLive.Diff do
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
    {:ok, assign_new(socket, :current_user, fn -> nil end)}
  end

  @impl Phoenix.LiveView
  def handle_params(
        %{"path_channel" => channel_name, "rev_a" => rev_a_hash, "rev_b" => rev_b_hash} = params,
        _url,
        socket
      ) do
    channel = Tracker.Nixpkgs.Channel.by_name!(channel_name)
    rev_a = ChannelRevision.find_by_channel_hash!(channel.id, rev_a_hash)
    rev_b = ChannelRevision.find_by_channel_hash!(channel.id, rev_b_hash)
    {older, newer} = order_revisions(rev_a, rev_b)

    {:noreply,
     socket
     |> assign(:page_title, "#{channel_name} diff")
     |> ComparisonState.load(channel_name, older, newer, params)}
  end

  @impl Phoenix.LiveView
  def handle_event("search", %{"search" => search}, socket) do
    {:noreply, ComparisonState.search(socket, search)}
  end

  defp order_revisions(%ChannelRevision{} = a, %ChannelRevision{} = b) do
    if DateTime.compare(a.released_at, b.released_at) == :gt, do: {b, a}, else: {a, b}
  end
end

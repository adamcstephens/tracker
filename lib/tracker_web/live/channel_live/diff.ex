defmodule TrackerWeb.ChannelLive.Diff do
  use TrackerWeb, :live_view

  import TrackerWeb.ChannelLive.DiffSections

  alias Tracker.Nixpkgs.ChannelRevision
  alias TrackerWeb.PageSearch

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      {@channel}
      <:subtitle>
        Comparing <.revision_link revision={@rev_a.revision} channel={@channel} /> &rarr;
        <.revision_link revision={@rev_b.revision} channel={@channel} /> &middot;
        <a
          href={"https://github.com/NixOS/nixpkgs/compare/#{@rev_a.revision}...#{@rev_b.revision}"}
          target="_blank"
          rel="noopener noreferrer"
        >
          GitHub diff
        </a>
      </:subtitle>
    </.header>

    <.revision_diff_sections
      diff={@diff}
      channel={@channel}
      heading_level={:h3}
      show_revision_column={true}
      empty_message="No changes between these revisions."
    />
    """
  end

  defp revision_link(assigns) do
    ~H"""
    <.link
      navigate={~p"/channels/#{@channel}/revisions/#{@revision}"}
      title={@revision}
      class="revision-link"
    >
      {String.slice(@revision, 0, 7)}
    </.link>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_new(socket, :current_user, fn -> nil end)}
  end

  @impl true
  def handle_params(
        %{"channel" => channel_name, "rev_a" => rev_a_hash, "rev_b" => rev_b_hash} = params,
        _url,
        socket
      ) do
    channel = Tracker.Nixpkgs.Channel.by_name!(channel_name)
    rev_a = ChannelRevision.find_by_channel_hash!(channel.id, rev_a_hash)
    rev_b = ChannelRevision.find_by_channel_hash!(channel.id, rev_b_hash)

    {older, newer} = order_revisions(rev_a, rev_b)

    diff = ChannelRevision.diff_between(older, newer)

    lens = socket.assigns.lens && %{socket.assigns.lens | disabled?: true}

    {:noreply,
     socket
     |> assign(:page_title, "#{channel_name} diff")
     |> assign(:channel, channel_name)
     |> assign(:rev_a, older)
     |> assign(:rev_b, newer)
     |> assign(:diff, diff)
     |> assign(:lens, lens)
     |> assign(:page_search, %PageSearch{
       mode: :inert,
       value: Map.get(params, "search", "")
     })}
  end

  defp order_revisions(a, b) do
    if DateTime.compare(a.released_at, b.released_at) == :gt, do: {b, a}, else: {a, b}
  end

  @impl true
  def handle_info({:set_lens, channel_name, rev}, socket) do
    {:noreply, TrackerWeb.LensHandlers.handle_lens_change(socket, channel_name, rev)}
  end
end

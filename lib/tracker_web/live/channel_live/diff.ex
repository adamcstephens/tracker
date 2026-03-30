defmodule TrackerWeb.ChannelLive.Diff do
  use TrackerWeb, :live_view

  alias Tracker.Nixpkgs.{ChannelRevision, PackageEvent}

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      {@channel}
      <:subtitle>
        Comparing <.revision_link revision={@rev_a.revision} /> &rarr;
        <.revision_link revision={@rev_b.revision} /> &middot;
        <a
          href={"https://github.com/NixOS/nixpkgs/compare/#{@rev_a.revision}...#{@rev_b.revision}"}
          target="_blank"
          rel="noopener noreferrer"
        >
          GitHub diff
        </a>
      </:subtitle>
    </.header>

    <section :if={@events != []}>
      <h3>Package Events</h3>
      <figure>
        <table role="grid">
          <thead>
            <tr>
              <th>Package</th>
              <th>Event</th>
              <th>Revision</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={event <- @events}>
              <td>
                <a href={~p"/packages/#{event.package.attribute}"}>{event.package.attribute}</a>
              </td>
              <td>{format_event_type(event.type)}</td>
              <td>
                <.revision_link revision={event.channel_revision.revision} />
              </td>
            </tr>
          </tbody>
        </table>
      </figure>
    </section>

    <section :if={@version_changes != []}>
      <h3>Version Changes</h3>
      <figure>
        <table role="grid">
          <thead>
            <tr>
              <th>Package</th>
              <th>Old Version</th>
              <th>New Version</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={change <- @version_changes}>
              <td>
                <a href={~p"/packages/#{change.attribute}"}>{change.attribute}</a>
              </td>
              <td>{change.old_version || "—"}</td>
              <td>{change.new_version || "—"}</td>
            </tr>
          </tbody>
        </table>
      </figure>
    </section>

    <p :if={@events == [] and @version_changes == []}>
      No changes between these revisions.
    </p>

    <.back navigate={~p"/channels/#{@channel}"}>Back to channel</.back>
    """
  end

  defp revision_link(assigns) do
    ~H"""
    <a
      href={"https://github.com/NixOS/nixpkgs/commit/#{@revision}"}
      target="_blank"
      rel="noopener noreferrer"
      title={@revision}
      class="revision-link"
    >
      {String.slice(@revision, 0, 7)}
    </a>
    """
  end

  defp format_event_type(:added), do: "added"
  defp format_event_type(:removed), do: "removed"

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_new(socket, :current_user, fn -> nil end)}
  end

  @impl true
  def handle_params(%{"rev_a" => rev_a_hash, "rev_b" => rev_b_hash}, _url, socket) do
    rev_a = ChannelRevision.find_by_hash!(rev_a_hash)
    rev_b = ChannelRevision.find_by_hash!(rev_b_hash)

    {older, newer} = order_revisions(rev_a, rev_b)
    channel = newer.channel

    events =
      PackageEvent.list_between_revisions!(channel, older.released_at, newer.released_at)

    version_changes = compute_version_changes(older.id, newer.id)

    {:noreply,
     socket
     |> assign(:page_title, "#{channel} diff")
     |> assign(:channel, channel)
     |> assign(:rev_a, older)
     |> assign(:rev_b, newer)
     |> assign(:events, events)
     |> assign(:version_changes, version_changes)}
  end

  defp order_revisions(a, b) do
    if DateTime.compare(a.released_at, b.released_at) == :gt, do: {b, a}, else: {a, b}
  end

  defp compute_version_changes(old_rev_id, new_rev_id) do
    ChannelRevision.version_diff(old_rev_id, new_rev_id)
  end
end

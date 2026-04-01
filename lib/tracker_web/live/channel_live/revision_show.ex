defmodule TrackerWeb.ChannelLive.RevisionShow do
  use TrackerWeb, :live_view

  alias Tracker.Nixpkgs.{ChannelRevision, PackageEvent}

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      {@channel}
      <:subtitle>
        Revision <.github_link revision={@revision.revision} /> &middot;
        Released {@formatted_released_at} &middot;
        Result: {format_result(@revision.result)}
      </:subtitle>
    </.header>

    <section :if={@previous_revision}>
      <h3>Changes from previous revision</h3>
      <p>
        Diff from <.github_link revision={@previous_revision.revision} /> &rarr;
        <.github_link revision={@revision.revision} /> &middot;
        <a
          href={"https://github.com/NixOS/nixpkgs/compare/#{@previous_revision.revision}...#{@revision.revision}"}
          target="_blank"
          rel="noopener noreferrer"
        >
          GitHub diff
        </a>
      </p>

      <section :if={@events != []}>
        <h4>Package Events</h4>
        <figure>
          <table role="grid">
            <thead>
              <tr>
                <th>Package</th>
                <th>Event</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={event <- @events}>
                <td>
                  <a href={~p"/packages/#{event.package.attribute}"}>{event.package.attribute}</a>
                </td>
                <td>{format_event_type(event.type)}</td>
              </tr>
            </tbody>
          </table>
        </figure>
      </section>

      <section :if={@version_changes != []}>
        <h4>Version Changes</h4>
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
        No changes from previous revision.
      </p>
    </section>

    <p :if={!@previous_revision}>
      This is the first known revision for this channel.
    </p>

    <.back navigate={~p"/channels/#{@channel}"}>Back to channel</.back>
    """
  end

  defp github_link(assigns) do
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

  defp format_result(nil), do: "-"
  defp format_result(:success), do: "Success"
  defp format_result(:partial_success), do: "Partial"
  defp format_result(:error), do: "Error"

  defp format_event_type(:added), do: "added"
  defp format_event_type(:removed), do: "removed"

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_new(socket, :current_user, fn -> nil end)}
  end

  @impl true
  def handle_params(%{"channel" => channel, "revision" => rev_hash}, _url, socket) do
    revision = ChannelRevision.find_by_channel_hash!(channel, rev_hash)

    previous_revision =
      if revision.previous_channel_revision_id do
        Ash.load!(revision, :previous_channel_revision).previous_channel_revision
      end

    {events, version_changes} =
      if previous_revision do
        events =
          PackageEvent.list_between_revisions!(
            channel,
            previous_revision.released_at,
            revision.released_at
          )

        version_changes = ChannelRevision.version_diff(previous_revision.id, revision.id)
        {events, version_changes}
      else
        {[], []}
      end

    {:noreply,
     socket
     |> assign(:page_title, "#{channel} — #{String.slice(revision.revision, 0, 7)}")
     |> assign(:channel, channel)
     |> assign(:revision, revision)
     |> assign(:previous_revision, previous_revision)
     |> assign(:formatted_released_at, Calendar.strftime(revision.released_at, "%Y-%m-%d %H:%M"))
     |> assign(:events, events)
     |> assign(:version_changes, version_changes)}
  end
end

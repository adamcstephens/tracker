defmodule TrackerWeb.ChannelLive.Diff do
  use TrackerWeb, :live_view

  alias Tracker.Nixpkgs.{ChannelRevision, OptionEvent, OptionRevision, PackageEvent}
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
                <.revision_link revision={event.channel_revision.revision} channel={@channel} />
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

    <section :if={@option_events != []}>
      <h3>Option Events</h3>
      <figure>
        <table role="grid">
          <thead>
            <tr>
              <th>Option</th>
              <th>Event</th>
              <th>Revision</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={event <- @option_events}>
              <td>
                <a href={~p"/options/#{event.option.name}"}>{event.option.name}</a>
              </td>
              <td>{format_event_type(event.type)}</td>
              <td>
                <.revision_link revision={event.channel_revision.revision} channel={@channel} />
              </td>
            </tr>
          </tbody>
        </table>
      </figure>
    </section>

    <section :if={@option_metadata_changes != []}>
      <h3>Option Metadata Changes</h3>
      <figure>
        <table role="grid">
          <thead>
            <tr>
              <th>Option</th>
              <th>Field</th>
              <th>Old</th>
              <th>New</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={change <- @option_metadata_changes}>
              <td>
                <a href={~p"/options/#{change.option_name}"}>{change.option_name}</a>
              </td>
              <td>{change.field}</td>
              <td>{format_metadata_value(change.old)}</td>
              <td>{format_metadata_value(change.new)}</td>
            </tr>
          </tbody>
        </table>
      </figure>
    </section>

    <p :if={
      @events == [] and @version_changes == [] and @option_events == [] and
        @option_metadata_changes == []
    }>
      No changes between these revisions.
    </p>
    """
  end

  defp format_metadata_value(nil), do: "—"
  defp format_metadata_value(true), do: "true"
  defp format_metadata_value(false), do: "false"
  defp format_metadata_value(value) when is_binary(value), do: value
  defp format_metadata_value(value), do: inspect(value)

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

  defp format_event_type(:added), do: "added"
  defp format_event_type(:removed), do: "removed"

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

    events =
      PackageEvent.list_between_revisions!(channel.id, older.released_at, newer.released_at)

    version_changes = compute_version_changes(older.id, newer.id)

    option_events =
      OptionEvent.list_between_revisions!(channel.id, older.released_at, newer.released_at)

    option_metadata_changes = OptionRevision.metadata_diff(older.id, newer.id)

    lens = socket.assigns.lens && %{socket.assigns.lens | disabled?: true}

    {:noreply,
     socket
     |> assign(:page_title, "#{channel_name} diff")
     |> assign(:channel, channel_name)
     |> assign(:rev_a, older)
     |> assign(:rev_b, newer)
     |> assign(:events, events)
     |> assign(:version_changes, version_changes)
     |> assign(:option_events, option_events)
     |> assign(:option_metadata_changes, option_metadata_changes)
     |> assign(:lens, lens)
     |> assign(:page_search, %PageSearch{
       mode: :inert,
       value: Map.get(params, "search", "")
     })}
  end

  defp order_revisions(a, b) do
    if DateTime.compare(a.released_at, b.released_at) == :gt, do: {b, a}, else: {a, b}
  end

  defp compute_version_changes(old_rev_id, new_rev_id) do
    ChannelRevision.version_diff(old_rev_id, new_rev_id)
  end

  @impl true
  def handle_info({:set_lens, channel_name, rev}, socket) do
    {:noreply, TrackerWeb.LensHandlers.handle_lens_change(socket, channel_name, rev)}
  end
end

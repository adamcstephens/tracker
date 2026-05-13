defmodule TrackerWeb.ChannelLive.RevisionShow do
  use TrackerWeb, :live_view

  alias Tracker.Nixpkgs.{ChannelRevision, OptionEvent, OptionRevision, PackageEvent}
  alias TrackerWeb.PageSearch

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

      <section :if={@option_events != []}>
        <h4>Option Events</h4>
        <figure>
          <table role="grid">
            <thead>
              <tr>
                <th>Option</th>
                <th>Event</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={event <- @option_events}>
                <td>
                  <a href={~p"/options/#{event.option.name}"}>{event.option.name}</a>
                </td>
                <td>{format_event_type(event.type)}</td>
              </tr>
            </tbody>
          </table>
        </figure>
      </section>

      <section :if={@option_metadata_changes != []}>
        <h4>Option Metadata Changes</h4>
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
        No changes from previous revision.
      </p>
    </section>

    <p :if={!@previous_revision}>
      This is the first known revision for this channel.
    </p>
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

  defp format_metadata_value(nil), do: "—"
  defp format_metadata_value(true), do: "true"
  defp format_metadata_value(false), do: "false"
  defp format_metadata_value(value) when is_binary(value), do: value
  defp format_metadata_value(value), do: inspect(value)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign_new(:current_user, fn -> nil end)
     |> assign(:subscribed_channel, nil)}
  end

  @impl true
  def handle_params(%{"channel" => channel_name, "revision" => rev_hash} = params, _url, socket) do
    channel = Tracker.Nixpkgs.Channel.by_name!(channel_name)

    if connected?(socket) && socket.assigns.subscribed_channel != channel_name do
      if socket.assigns.subscribed_channel do
        Phoenix.PubSub.unsubscribe(
          Tracker.PubSub,
          "channel_revisions:#{socket.assigns.subscribed_channel}"
        )
      end

      Phoenix.PubSub.subscribe(Tracker.PubSub, "channel_revisions:#{channel_name}")
    end

    revision = ChannelRevision.find_by_channel_hash!(channel.id, rev_hash)

    lens = socket.assigns.lens && %{socket.assigns.lens | disabled?: true}

    {:noreply,
     socket
     |> assign(:channel, channel_name)
     |> assign(:channel_id, channel.id)
     |> assign(:subscribed_channel, channel_name)
     |> assign(:lens, lens)
     |> assign(:page_search, %PageSearch{
       mode: :inert,
       value: Map.get(params, "search", "")
     })
     |> assign_revision_data(revision)}
  end

  @impl true
  def handle_info({:channel_revision_completed, _payload}, socket) do
    revision =
      ChannelRevision.find_by_channel_hash!(
        socket.assigns.channel_id,
        socket.assigns.revision.revision
      )

    {:noreply, assign_revision_data(socket, revision)}
  end

  def handle_info({:set_lens, channel_name, rev}, socket) do
    {:noreply, TrackerWeb.LensHandlers.handle_lens_change(socket, channel_name, rev)}
  end

  defp assign_revision_data(socket, revision) do
    channel_name = socket.assigns[:channel] || ""

    previous_revision =
      if revision.previous_channel_revision_id do
        Ash.load!(revision, :previous_channel_revision).previous_channel_revision
      end

    {events, version_changes, option_events, option_metadata_changes} =
      if previous_revision do
        events =
          PackageEvent.list_between_revisions!(
            revision.channel_id,
            previous_revision.released_at,
            revision.released_at
          )

        version_changes = ChannelRevision.version_diff(previous_revision.id, revision.id)

        option_events =
          OptionEvent.list_between_revisions!(
            revision.channel_id,
            previous_revision.released_at,
            revision.released_at
          )

        option_metadata_changes = OptionRevision.metadata_diff(previous_revision.id, revision.id)

        {events, version_changes, option_events, option_metadata_changes}
      else
        {[], [], [], []}
      end

    socket
    |> assign(:page_title, "#{channel_name} — #{String.slice(revision.revision, 0, 7)}")
    |> assign(:revision, revision)
    |> assign(:previous_revision, previous_revision)
    |> assign(:formatted_released_at, Calendar.strftime(revision.released_at, "%Y-%m-%d %H:%M"))
    |> assign(:events, events)
    |> assign(:version_changes, version_changes)
    |> assign(:option_events, option_events)
    |> assign(:option_metadata_changes, option_metadata_changes)
  end
end

defmodule TrackerWeb.ChannelLive.Show do
  @moduledoc """
  Channel metadata and paginated revisions with native-form comparison selection.
  """
  use TrackerWeb, :live_view

  alias Tracker.Notifications.ChannelSubscription
  alias TrackerWeb.PageSearch
  alias TrackerWeb.Pagination
  alias TrackerWeb.RowList
  alias TrackerWeb.SectionHeader
  alias TrackerWeb.Time
  alias TrackerWeb.TableParams

  @impl true
  def render(assigns) do
    ~H"""
    <section class="channel-show">
      <header class="channel-show__header">
        <div class="channel-show__title">
          <h1>{@channel}</h1>
          <div
            :if={
              @channel_resource.status in [:pre_release, :deprecated, :retired] ||
                @channel_resource.build_problem?
            }
            class="channel-show__status"
          >
            <.badge :if={@channel_resource.status == :pre_release} variant={:warn}>Beta</.badge>
            <.badge :if={@channel_resource.status == :deprecated} variant={:warn}>Deprecated</.badge>
            <.badge :if={@channel_resource.status == :retired}>Retired</.badge>
            <.badge :if={@channel_resource.build_problem?} variant={:danger}>
              <svg
                aria-hidden="true"
                width="12"
                height="12"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="2"
              ><path d="m12 3 10 18H2L12 3Z" /><path d="M12 9v5m0 3v1" /></svg>
              Build problem
            </.badge>
          </div>
        </div>
        <div class="channel-show__actions">
          <.link
            :if={@channel_resource.hydra_project && @channel_resource.hydra_jobset}
            id="hydra-jobset"
            href={"https://hydra.nixos.org/jobset/#{@channel_resource.hydra_project}/#{@channel_resource.hydra_jobset}"}
            target="_blank"
            rel="noopener noreferrer"
            aria-label={"Hydra jobset for #{@channel} (opens in new tab)"}
          >
            Hydra jobset
            <svg
              aria-hidden="true"
              width="14"
              height="14"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
            ><path d="M14 3h7v7m0-7L10 14" /><path d="M10 3H3v18h18v-7" /></svg>
          </.link>
          <a
            id="feed-link"
            href={"/feeds/channels/#{@channel}"}
            phx-hook="CopyLink"
            title="Copy the Atom feed URL"
          >
            <svg
              aria-hidden="true"
              width="16"
              height="16"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.7"
              stroke-linecap="round"
            ><circle cx="5" cy="19" r="1" /><path d="M4 11a9 9 0 0 1 9 9M4 4a16 16 0 0 1 16 16" /></svg>
            Atom feed
          </a>
          <button
            :if={@current_user}
            id="subscribe-toggle"
            type="button"
            phx-click="toggle-subscription"
          >
            {if @subscribed?, do: "Unsubscribe", else: "Subscribe"}
          </button>
        </div>
      </header>

      <form
        :if={@has_revisions?}
        id="revisions-form"
        method="get"
        action={~p"/channels/#{@channel}/diff"}
      >
        <SectionHeader.section_header title="Revisions" count={@revision_count} />
        <div class="channel-show__panel">
          <div id="comparison-toolbar" class="channel-show__toolbar">
            <div class="channel-show__selection-summary" aria-live="polite">
              <span id="comparison-guidance">Select two revisions to compare.</span>
              <div class="channel-show__endpoints" hidden>
                <span>From <code id="comparison-from">—</code></span>
                <span aria-hidden="true">→</span>
                <span>To <code id="comparison-to">—</code></span>
              </div>
            </div>
            <div class="channel-show__controls">
              <button id="clear-selection" type="button" hidden>Clear selection</button>
              <button id="compare-selected" type="submit" disabled>Compare selected</button>
            </div>
          </div>
          <RowList.row_list id="revisions" stacked>
            <RowList.row :for={rev <- @revisions} id={"revision-#{rev.id}"} mode={:plain}>
              <:leading>
                <input
                  id={"select-#{rev.id}"}
                  type="checkbox"
                  name="compare[]"
                  value={rev.revision}
                  data-released-at={DateTime.to_iso8601(rev.released_at)}
                  aria-label={"Select revision #{String.slice(rev.revision, 0, 7)}"}
                />
              </:leading>
              <:label>
                <.revision_link revision={rev.revision} channel={@channel} />
                <span
                  :if={rev.released_at == @channel_resource.latest_release}
                  class="channel-show__latest"
                >Latest</span>
                <span class="channel-show__endpoint"></span>
              </:label>
              <:meta>{format_date(rev.released_at, @time_zone)}</:meta>
            </RowList.row>
          </RowList.row_list>
        </div>

        <Pagination.controls
          total_pages={@total_pages}
          current_page={@current_page}
          has_prev_page?={@has_prev_page?}
          has_next_page?={@has_next_page?}
          prev_path={TableParams.page_path(@table_params, @current_page - 1, "/channels/#{@channel}")}
          next_path={TableParams.page_path(@table_params, @current_page + 1, "/channels/#{@channel}")}
          anchor="revisions"
        />
        <footer class="channel-show__footer">
          <span>Showing {@table_params.offset + 1}–{@table_params.offset + length(@revisions)} of {@revision_count} revisions</span>
          <span>Release times in {if @time_zone == "Etc/UTC", do: "UTC", else: @time_zone}</span>
        </footer>
      </form>

      <p :if={not @has_revisions?}>
        No revisions found.
      </p>
    </section>
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

  defp format_date(nil, _time_zone), do: "-"
  defp format_date(dt, time_zone), do: Time.format_datetime(dt, time_zone)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign_new(:current_user, fn -> nil end)
     |> assign(:subscribed?, false)
     |> assign(:subscribed_channel_id, nil)}
  end

  @impl true
  def handle_params(%{"path_channel" => channel_name} = params, _url, socket) do
    channel =
      Tracker.Nixpkgs.Channel.by_name!(channel_name, load: [:build_problem?, :latest_release])

    if connected?(socket) && socket.assigns.subscribed_channel_id != channel.id do
      if socket.assigns.subscribed_channel_id do
        Phoenix.PubSub.unsubscribe(
          Tracker.PubSub,
          "channel_revisions:#{socket.assigns.subscribed_channel_id}:created"
        )

        Phoenix.PubSub.unsubscribe(
          Tracker.PubSub,
          "channel_revisions:#{socket.assigns.subscribed_channel_id}:completed"
        )
      end

      Phoenix.PubSub.subscribe(Tracker.PubSub, "channel_revisions:#{channel.id}:created")
      Phoenix.PubSub.subscribe(Tracker.PubSub, "channel_revisions:#{channel.id}:completed")
    end

    tp = TableParams.from_params(params)

    lens = socket.assigns.lens && %{socket.assigns.lens | disabled?: true}

    {:noreply,
     socket
     |> assign(:page_title, channel_name)
     |> assign(:channel, channel_name)
     |> assign(:channel_resource, channel)
     |> assign(:table_params, tp)
     |> assign(:subscribed_channel_id, channel.id)
     |> assign(:subscribed?, channel_subscribed?(socket.assigns.current_user, channel.id))
     |> assign(:lens, lens)
     |> assign(:page_search, %PageSearch{
       mode: :inert,
       value: Map.get(params, "search", "")
     })
     |> assign_revisions(channel.id)}
  end

  @impl true
  def handle_info(
        %Ash.Notifier.Notification{resource: Tracker.Nixpkgs.ChannelRevision},
        socket
      ) do
    channel =
      Tracker.Nixpkgs.Channel.by_name!(socket.assigns.channel,
        load: [:build_problem?, :latest_release]
      )

    {:noreply, socket |> assign(:channel_resource, channel) |> assign_revisions(channel.id)}
  end

  defp channel_subscribed?(nil, _channel_id), do: false

  defp channel_subscribed?(user, channel_id) do
    case ChannelSubscription.find(channel_id, actor: user) do
      {:ok, nil} -> false
      {:ok, _subscription} -> true
    end
  end

  defp assign_revisions(socket, channel_id) do
    tp = socket.assigns.table_params

    page =
      Tracker.Nixpkgs.ChannelRevision.list_by_channel!(channel_id,
        query: [sort: [released_at: :desc]],
        page: [offset: tp.offset, count: true]
      )

    pagination = TableParams.apply_pagination(tp, page, :revisions)

    socket
    |> assign(:revisions, pagination.stream_results)
    |> assign(:revision_count, page.count)
    |> assign(:has_revisions?, pagination.stream_results != [])
    |> assign(:has_prev_page?, pagination.has_prev_page?)
    |> assign(:has_next_page?, pagination.has_next_page?)
    |> assign(:total_pages, pagination.total_pages)
    |> assign(:current_page, pagination.current_page)
  end

  @impl true
  def handle_event("toggle-subscription", _params, socket) do
    %{current_user: user, channel_resource: channel} = socket.assigns

    subscribed? =
      case ChannelSubscription.find(channel.id, actor: user) do
        {:ok, nil} ->
          {:ok, _subscription} = ChannelSubscription.subscribe(channel.id, actor: user)
          true

        {:ok, subscription} ->
          :ok = ChannelSubscription.destroy(subscription, actor: user)
          false
      end

    {:noreply, assign(socket, :subscribed?, subscribed?)}
  end
end

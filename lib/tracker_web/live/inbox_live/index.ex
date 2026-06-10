defmodule TrackerWeb.InboxLive.Index do
  @moduledoc """
  The per-user in-app inbox. A triage view over durable notifications:
  unread/all segment, multi-select type filter chips, chrome search over
  row text, day-grouped rows with per-row read/unread toggling. Updates
  live as new ones are inserted, and doubles as the "everything
  affected" view when filtered to a single channel revision.

  The sitewide lens renders disabled here: notifications are
  point-in-time events on subscriptions, so channel-scoping them would
  hide unread items and only some types map to a channel at all.
  """
  use TrackerWeb, :live_view

  on_mount {TrackerWeb.LiveUserAuth, :live_user_required}

  alias Tracker.Notifications.Notification
  alias TrackerWeb.FeedLink
  alias TrackerWeb.NotificationPresenter
  alias TrackerWeb.PageSearch

  @impl true
  def mount(_params, _session, socket) do
    user = FeedLink.ensure_token(socket.assigns.current_user)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Tracker.PubSub, "notifications:#{user.id}")
    end

    {:ok,
     socket
     |> assign(:current_user, user)
     |> assign(:page_title, "Inbox")
     |> assign(:unread_filter, :unread)
     |> assign(:active_types, MapSet.new())
     |> assign(:feed_path, FeedLink.path(user))}
  end

  @impl true
  def handle_params(params, _url, socket) do
    channel_revision_id =
      case Integer.parse(params["channel_revision_id"] || "") do
        {id, _} -> id
        :error -> nil
      end

    search = params["search"] || ""

    hidden =
      case channel_revision_id do
        nil -> %{}
        id -> %{"channel_revision_id" => Integer.to_string(id)}
      end

    lens = socket.assigns.lens && %{socket.assigns.lens | disabled?: true}

    {:noreply,
     socket
     |> assign(:channel_revision_id, channel_revision_id)
     |> assign(:search, search)
     |> assign(:lens, lens)
     |> assign(:page_search, %PageSearch{
       action: "/inbox",
       value: search,
       placeholder: "Search notifications…",
       hidden: hidden
     })
     |> load_notifications()}
  end

  @impl true
  def handle_event("toggle-read", %{"id" => id}, socket) do
    id = String.to_integer(id)
    user = socket.assigns.current_user

    case Enum.find(socket.assigns.notifications, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      %{read_at: nil} = notification ->
        {:ok, _} = Notification.mark_read(notification, actor: user)
        {:noreply, load_notifications(socket)}

      notification ->
        {:ok, _} = Notification.mark_unread(notification, actor: user)
        {:noreply, load_notifications(socket)}
    end
  end

  def handle_event("search", %{"search" => search}, socket) do
    {:noreply,
     socket
     |> assign(:search, search)
     |> update(:page_search, &%{&1 | value: search})
     |> apply_filters()
     |> push_event("update-url", %{
       path: inbox_path(socket.assigns.channel_revision_id, search)
     })}
  end

  def handle_event("set-unread-filter", %{"filter" => filter}, socket) do
    unread_filter = if filter == "unread", do: :unread, else: :all

    {:noreply,
     socket
     |> assign(:unread_filter, unread_filter)
     |> apply_filters()}
  end

  def handle_event("toggle-type", %{"type" => type}, socket) do
    type = Enum.find(NotificationPresenter.type_order(), &(Atom.to_string(&1) == type))
    active = socket.assigns.active_types

    active =
      if MapSet.member?(active, type),
        do: MapSet.delete(active, type),
        else: MapSet.put(active, type)

    {:noreply,
     socket
     |> assign(:active_types, active)
     |> apply_filters()}
  end

  def handle_event("mark-all-read", _params, socket) do
    user = socket.assigns.current_user

    socket.assigns.notifications
    |> Enum.filter(&is_nil(&1.read_at))
    |> case do
      [] -> :ok
      unread -> Ash.bulk_update!(unread, :mark_read, %{}, actor: user, return_records?: false)
    end

    {:noreply, load_notifications(socket)}
  end

  @impl true
  def handle_info(%Ash.Notifier.Notification{resource: Notification}, socket) do
    {:noreply, load_notifications(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp load_notifications(socket) do
    user = socket.assigns.current_user

    params =
      case socket.assigns.channel_revision_id do
        nil -> %{}
        id -> %{channel_revision_id: id}
      end

    notifications = Notification.for_user!(params, actor: user)
    unread_count = Enum.count(notifications, &is_nil(&1.read_at))

    socket
    |> assign(:notifications, notifications)
    |> assign(:version_changes, NotificationPresenter.version_changes(notifications))
    |> assign(:unread_count, unread_count)
    |> assign(:unread_notification_count, unread_count)
    |> apply_filters()
  end

  defp apply_filters(socket) do
    %{
      notifications: notifications,
      unread_filter: unread_filter,
      active_types: active_types,
      search: search,
      version_changes: version_changes
    } = socket.assigns

    query = search |> String.trim() |> String.downcase()

    in_segment =
      Enum.filter(notifications, fn n ->
        (unread_filter == :all or is_nil(n.read_at)) and
          search_match?(n, version_changes, query)
      end)

    visible =
      Enum.filter(in_segment, fn n ->
        MapSet.size(active_types) == 0 or MapSet.member?(active_types, n.type)
      end)

    now = DateTime.utc_now()

    socket
    |> assign(:now, now)
    |> assign(:type_counts, Enum.frequencies_by(in_segment, & &1.type))
    |> assign(:groups, NotificationPresenter.group_by_day(visible, now))
  end

  defp search_match?(_n, _version_changes, ""), do: true

  defp search_match?(n, version_changes, query) do
    [
      NotificationPresenter.hero(n, version_changes),
      n.channel && n.channel.name,
      n.change_branch && n.change_branch.branch_name
    ]
    |> Enum.any?(fn text ->
      is_binary(text) and String.contains?(String.downcase(text), query)
    end)
  end

  defp inbox_path(channel_revision_id, search) do
    params =
      %{"channel_revision_id" => channel_revision_id, "search" => search}
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)

    case params do
      [] -> ~p"/inbox"
      params -> ~p"/inbox?#{params}"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="ibx">
      <div class="ibx-toolbar">
        <div class="ibx-seg" role="group" aria-label="Read state filter">
          <button
            id="filter-unread"
            type="button"
            class={@unread_filter == :unread && "is-active"}
            phx-click="set-unread-filter"
            phx-value-filter="unread"
          >
            Unread <span class="n">{@unread_count}</span>
          </button>
          <button
            id="filter-all"
            type="button"
            class={@unread_filter == :all && "is-active"}
            phx-click="set-unread-filter"
            phx-value-filter="all"
          >
            All <span class="n">{length(@notifications)}</span>
          </button>
        </div>

        <div class="ibx-actions">
          <button
            id="mark-all-read"
            type="button"
            class="ibx-btn ibx-btn--primary"
            phx-click="mark-all-read"
            disabled={@unread_count == 0}
          >
            <.icon name="check" /> Mark all read
          </button>
          <a
            :if={@feed_path}
            id="feed-link"
            class="ibx-iconbtn"
            href={@feed_path}
            phx-hook="CopyLink"
            title="Copy your private Atom feed URL"
            aria-label="Copy your private Atom feed URL"
          >
            <.icon name="rss" />
          </a>
        </div>

        <div class="ibx-filters" role="group" aria-label="Type filters">
          <button
            :for={type <- NotificationPresenter.type_order()}
            id={"filter-type-#{type}"}
            type="button"
            class={["ibx-chip", MapSet.member?(@active_types, type) && "is-active"]}
            phx-click="toggle-type"
            phx-value-type={type}
          >
            <span class={["swatch", "ibx-t-#{NotificationPresenter.type_class(type)}"]}></span>
            {NotificationPresenter.type_filter_label(type)}
            <span class="n">{Map.get(@type_counts, type, 0)}</span>
          </button>
        </div>
      </div>

      <p :if={@channel_revision_id} class="flash flash--info">
        Showing notifications for one revision. <.link navigate={~p"/inbox"}>Show all</.link>
      </p>

      <p :if={@notifications == []} id="inbox-empty" class="ibx-empty">No notifications yet.</p>

      <div :if={@notifications != [] && @groups == []} class="ibx-empty">
        Nothing matches these filters.
      </div>

      <section :for={{day, rows} <- @groups} class="ibx-day">
        <div class="ibx-day-head">
          <h2>{day}</h2>
          <span class="rule"></span>
          <span class="n">{length(rows)}</span>
        </div>
        <ul class="ibx-list">
          <.row :for={n <- rows} n={n} now={@now} version_changes={@version_changes} />
        </ul>
      </section>
    </div>
    """
  end

  attr :n, :map, required: true
  attr :now, :any, required: true
  attr :version_changes, :map, required: true

  defp row(assigns) do
    assigns =
      assigns
      |> assign(:type_class, NotificationPresenter.type_class(assigns.n.type))
      |> assign(:path, NotificationPresenter.path(assigns.n))
      |> assign(:hero, NotificationPresenter.hero(assigns.n, assigns.version_changes))

    ~H"""
    <li
      id={"notification-#{@n.id}"}
      class={["ibx-row", if(is_nil(@n.read_at), do: "is-unread", else: "is-read")]}
      style={"--type-color: var(--t-#{@type_class})"}
    >
      <span class="ibx-glyph"><.icon name={@type_class} /></span>
      <div class="ibx-body">
        <div class="ibx-line1">
          <span class={hero_class(@n.type)}>
            <%= if @path do %>
              <.link navigate={@path}>{@hero}</.link>
            <% else %>
              {@hero}
            <% end %>
          </span>
        </div>
        <div class="ibx-line2">
          <span class="ibx-typechip">
            <span class="dot"></span>{NotificationPresenter.type_label(@n.type)}
          </span>
          <%= if @n.type == :change_propagated do %>
            <.link :if={@path} navigate={@path} class="ibx-tag ibx-tag--pr">
              PR <span class="hash">#{@n.change && @n.change.number}</span>
            </.link>
            <span :if={@n.change_branch} class="ibx-tag ibx-tag--reached">
              reached {@n.change_branch.branch_name}
            </span>
          <% else %>
            <span :if={@n.channel} class="ibx-tag">
              <span class="dot"></span>{@n.channel.name}
            </span>
          <% end %>
          <span class="ibx-dot-sep">·</span>
          <time class="ibx-time" title={NotificationPresenter.clock_utc(@n.occurred_at)}>
            {NotificationPresenter.relative_time(@n.occurred_at, @now)}
          </time>
        </div>
      </div>
      <div class="ibx-right">
        <span :if={is_nil(@n.read_at)} class="ibx-unread-dot" title="Unread"></span>
        <div class="ibx-row-acts">
          <button
            type="button"
            class="ibx-act"
            phx-click="toggle-read"
            phx-value-id={@n.id}
            title={if is_nil(@n.read_at), do: "Mark as read", else: "Mark as unread"}
            aria-label={if is_nil(@n.read_at), do: "Mark as read", else: "Mark as unread"}
          >
            <.icon name={if is_nil(@n.read_at), do: "check", else: "unread"} />
          </button>
          <.link :if={@path} navigate={@path} class="ibx-act" title="Open" aria-label="Open">
            <.icon name="external" />
          </.link>
        </div>
      </div>
    </li>
    """
  end

  defp hero_class(:change_propagated), do: "ibx-title"
  defp hero_class(_type), do: "ibx-attr"

  attr :name, :string, required: true

  defp icon(assigns) do
    ~H"""
    <svg
      class="ibx-icon"
      aria-hidden="true"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.7"
      stroke-linecap="round"
      stroke-linejoin="round"
    >
      <%= case @name do %>
        <% "update" -> %>
          <path d="M21 12a9 9 0 1 1-3-6.7" /><path d="M21 4v5h-5" />
        <% "add" -> %>
          <path d="M12 5v14M5 12h14" />
        <% "remove" -> %>
          <path d="M5 12h14" />
        <% "revision" -> %>
          <path d="M3 12h4l3 7 4-14 3 7h4" />
        <% "propagate" -> %>
          <circle cx="6" cy="6" r="2.5" /><circle cx="6" cy="18" r="2.5" /><circle
            cx="18"
            cy="18"
            r="2.5"
          /><path d="M6 8.5v3a4 4 0 0 0 4 4h5.5" />
        <% "check" -> %>
          <path d="M20 6 9 17l-5-5" />
        <% "unread" -> %>
          <circle cx="12" cy="12" r="8" /><circle
            cx="12"
            cy="12"
            r="3.1"
            fill="currentColor"
            stroke="none"
          />
        <% "external" -> %>
          <path d="M14 4h6v6" /><path d="M20 4 10 14" /><path d="M19 13v6a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1h6" />
        <% "rss" -> %>
          <path d="M4 11a9 9 0 0 1 9 9" /><path d="M4 4a16 16 0 0 1 16 16" /><circle
            cx="5"
            cy="19"
            r="1.4"
            fill="currentColor"
            stroke="none"
          />
      <% end %>
    </svg>
    """
  end
end

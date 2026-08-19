defmodule TrackerWeb.InboxLive.Index do
  @moduledoc """
  The per-user in-app inbox. A triage view over durable notifications:
  unread/all segment, multi-select type filter chips, chrome search over
  the package, channel, change and branch a row references, day-grouped
  rows with per-row read/unread toggling. Updates live as new ones are
  inserted, and doubles as the "everything affected" view when filtered
  to a single channel revision.

  Every filter is a `for_user` argument and every count its own query, so
  a page costs 25 rows no matter how long the history is. The URL carries
  the whole view — page, segment, types, search — and is what a reload or
  a shared link restores.

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
  alias TrackerWeb.Pagination
  alias TrackerWeb.RowList
  alias TrackerWeb.SectionHeader
  alias TrackerWeb.TableParams

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
     |> assign(:feed_path, FeedLink.path(user))}
  end

  @impl true
  def handle_params(params, _url, socket) do
    channel_revision_id =
      case Integer.parse(params["channel_revision_id"] || "") do
        {id, _} -> id
        :error -> nil
      end

    tp = TableParams.from_params(params, page_size: 25)

    unread_filter = if params["filter"] == "all", do: :all, else: :unread
    active_types = parse_types(params["types"])
    lens = socket.assigns.lens && %{socket.assigns.lens | disabled?: true}

    {:noreply,
     socket
     |> assign(:channel_revision_id, channel_revision_id)
     |> assign(:table_params, tp)
     |> assign(:unread_filter, unread_filter)
     |> assign(:active_types, active_types)
     |> assign(:lens, lens)
     |> assign_page_search()
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
    socket
    |> update(:table_params, &%{&1 | search: search})
    |> reset_to_first_page()
  end

  def handle_event("set-unread-filter", %{"filter" => filter}, socket) do
    socket
    |> assign(:unread_filter, if(filter == "unread", do: :unread, else: :all))
    |> reset_to_first_page()
  end

  def handle_event("toggle-type", %{"type" => type}, socket) do
    type = Enum.find(NotificationPresenter.type_order(), &(Atom.to_string(&1) == type))
    active = socket.assigns.active_types

    active =
      if MapSet.member?(active, type),
        do: MapSet.delete(active, type),
        else: MapSet.put(active, type)

    socket
    |> assign(:active_types, active)
    |> reset_to_first_page()
  end

  def handle_event("next-page", _params, socket) do
    {:noreply, patch_to_page(socket, socket.assigns.table_params.page + 1)}
  end

  def handle_event("prev-page", _params, socket) do
    {:noreply, patch_to_page(socket, max(socket.assigns.table_params.page - 1, 1))}
  end

  def handle_event("mark-all-read", _params, socket) do
    user = socket.assigns.current_user

    Notification.for_user!(
      %{channel_revision_id: socket.assigns.channel_revision_id, unread_only: true},
      actor: user
    )
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

  # Filter changes re-query from the top: the row that pushed you onto page 3
  # is rarely still there once the filter moves.
  defp reset_to_first_page(socket) do
    socket = update(socket, :table_params, &%{&1 | page: 1, offset: 0})

    {:noreply,
     socket
     |> assign_page_search()
     |> load_notifications()
     |> push_event("update-url", %{path: inbox_path(socket)})}
  end

  defp patch_to_page(socket, page) do
    tp = %{socket.assigns.table_params | page: page}
    push_patch(socket, to: TableParams.to_path(tp, "/inbox", extra_params(socket.assigns)))
  end

  defp assign_page_search(socket) do
    tp = socket.assigns.table_params

    assign(socket, :page_search, %PageSearch{
      action: "/inbox",
      value: tp.search,
      placeholder: "Search notifications…",
      hidden: TableParams.to_hidden_inputs(tp, extra_params(socket.assigns))
    })
  end

  defp load_notifications(socket) do
    %{current_user: user, table_params: tp} = socket.assigns

    page =
      Notification.for_user!(query_args(socket),
        page: [offset: tp.offset, limit: tp.page_size, count: true],
        actor: user
      )

    pagination = TableParams.apply_pagination(tp, page, :notifications)
    unread_count = count(socket, %{unread_only: true})
    now = DateTime.utc_now()

    socket
    |> assign(:notifications, page.results)
    |> assign(:version_changes, NotificationPresenter.version_changes(page.results))
    |> assign(:groups, NotificationPresenter.group_by_day(page.results, now))
    |> assign(:now, now)
    |> assign(:unread_count, unread_count)
    |> assign(:unread_notification_count, unread_count)
    |> assign(:total_count, count(socket, %{}))
    |> assign(:type_counts, type_counts(socket))
    |> assign(:has_prev_page?, pagination.has_prev_page?)
    |> assign(:has_next_page?, pagination.has_next_page?)
    |> assign(:total_pages, pagination.total_pages)
    |> assign(:current_page, pagination.current_page)
  end

  # The segment tallies count the whole scope; the chips count within the
  # active segment and search, so they read as "what selecting me would show".
  defp type_counts(socket) do
    %{search: search} = socket.assigns.table_params

    Map.new(NotificationPresenter.type_order(), fn type ->
      {type,
       count(socket, %{
         unread_only: socket.assigns.unread_filter == :unread,
         search: search,
         types: [type]
       })}
    end)
  end

  defp count(socket, args) do
    args = Map.put(args, :channel_revision_id, socket.assigns.channel_revision_id)

    Notification.for_user!(args,
      page: [limit: 1, count: true],
      actor: socket.assigns.current_user
    ).count
  end

  defp query_args(socket) do
    %{active_types: active_types, table_params: tp} = socket.assigns

    %{
      channel_revision_id: socket.assigns.channel_revision_id,
      unread_only: socket.assigns.unread_filter == :unread,
      types: if(MapSet.size(active_types) == 0, do: nil, else: MapSet.to_list(active_types)),
      search: tp.search
    }
  end

  defp parse_types(nil), do: MapSet.new()

  defp parse_types(types) do
    names = String.split(types, ",", trim: true)
    MapSet.new(Enum.filter(NotificationPresenter.type_order(), &(Atom.to_string(&1) in names)))
  end

  defp extra_params(assigns) do
    %{active_types: active_types} = assigns

    %{
      channel_revision_id: assigns.channel_revision_id,
      filter: assigns.unread_filter == :all && "all",
      types: active_types |> Enum.sort() |> Enum.map_join(",", &Atom.to_string/1)
    }
  end

  defp inbox_path(socket) do
    TableParams.to_path(socket.assigns.table_params, "/inbox", extra_params(socket.assigns))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="ibx">
      <div class="ibx-toolbar">
        <.view_nav active={:inbox} />
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
            All <span class="n">{@total_count}</span>
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

      <p :if={@total_count == 0} id="inbox-empty" class="ibx-empty">No notifications yet.</p>

      <div :if={@total_count > 0 && @groups == []} class="ibx-empty">
        Nothing matches these filters.
      </div>

      <section :for={{{day, rows}, index} <- Enum.with_index(@groups)}>
        <SectionHeader.section_header title={day} count={length(rows)} />
        <RowList.row_list id={"inbox-day-#{index}"}>
          <.row :for={n <- rows} n={n} now={@now} version_changes={@version_changes} />
        </RowList.row_list>
      </section>

      <Pagination.controls
        total_pages={@total_pages}
        current_page={@current_page}
        has_prev_page?={@has_prev_page?}
        has_next_page?={@has_next_page?}
        prev_path={
          TableParams.page_path(@table_params, @current_page - 1, "/inbox", extra_params(assigns))
        }
        next_path={
          TableParams.page_path(@table_params, @current_page + 1, "/inbox", extra_params(assigns))
        }
      />
    </div>
    """
  end

  attr :active, :atom, required: true, values: [:inbox, :subscriptions]

  def view_nav(assigns) do
    ~H"""
    <nav class="ibx-seg" aria-label="Inbox views">
      <.link
        id="view-nav-inbox"
        navigate={~p"/inbox"}
        class={@active == :inbox && "is-active"}
        aria-current={@active == :inbox && "page"}
      >
        Inbox
      </.link>
      <.link
        id="view-nav-subscriptions"
        navigate={~p"/inbox/subscriptions"}
        class={@active == :subscriptions && "is-active"}
        aria-current={@active == :subscriptions && "page"}
      >
        Subscriptions
      </.link>
    </nav>
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
    <RowList.row
      id={"notification-#{@n.id}"}
      mode={:plain}
      class={if is_nil(@n.read_at), do: "is-unread", else: "is-read"}
      style={"--type-color: var(--t-#{@type_class})"}
    >
      <:leading><span class="ibx-glyph"><.icon name={@type_class} /></span></:leading>
      <:label>
        <span class={hero_class(@n.type)}>
          <%= if @path do %>
            <.link navigate={@path}>{@hero}</.link>
          <% else %>
            {@hero}
          <% end %>
        </span>
      </:label>
      <:sublabel>
        <span class="pill ibx-typechip">
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
          <.link :if={@n.change} navigate={@path} class="ibx-tag ibx-tag--pr">
            PR <span class="hash">#{@n.change.number}</span>
          </.link>
          <.link
            :if={@n.change && @n.package}
            navigate={~p"/packages/#{@n.package.attribute}"}
            class="ibx-tag ibx-tag--package"
          >
            {@n.package.attribute}
          </.link>
          <span :if={@n.channel} class="ibx-tag">
            <span class="dot"></span>{@n.channel.name}
          </span>
        <% end %>
        <span class="ibx-dot-sep">·</span>
        <time class="ibx-time" title={NotificationPresenter.clock_utc(@n.occurred_at)}>
          {NotificationPresenter.relative_time(@n.occurred_at, @now)}
        </time>
      </:sublabel>
      <:actions>
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
      </:actions>
    </RowList.row>
    """
  end

  defp hero_class(type)
       when type in [:change_propagated, :package_change_opened, :package_change_merged],
       do: "ibx-title"

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
        <% "pr-open" -> %>
          <circle cx="7" cy="6" r="2.5" /><circle cx="7" cy="18" r="2.5" /><path d="M7 8.5v7" /><circle
            cx="17"
            cy="18"
            r="2.5"
          /><path d="M17 15.5V9a3 3 0 0 0-3-3h-3" />
        <% "pr-merged" -> %>
          <circle cx="7" cy="6" r="2.5" /><circle cx="7" cy="18" r="2.5" /><path d="M7 8.5v7" /><circle
            cx="17"
            cy="12"
            r="2.5"
          /><path d="M14.5 12h-2A5.5 5.5 0 0 1 7 6.5" />
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

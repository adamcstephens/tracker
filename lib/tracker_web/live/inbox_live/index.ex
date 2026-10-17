defmodule TrackerWeb.InboxLive.Index do
  @moduledoc """
  The per-user in-app inbox. A triage view over durable notifications:
  unread/all/saved segment, multi-select type filter chips, chrome search over
  the package, channel, change and branch a row references, day-grouped
  rows with independent read/unread and saved toggles. Updates live as new ones are
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

    filter = parse_filter(params["filter"])
    active_types = parse_types(params["types"])
    lens = socket.assigns.lens && %{socket.assigns.lens | disabled?: true}

    {:noreply,
     socket
     |> assign(:channel_revision_id, channel_revision_id)
     |> assign(:table_params, tp)
     |> assign(:filter, filter)
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

  def handle_event("toggle-saved", %{"id" => id}, socket) do
    id = String.to_integer(id)
    user = socket.assigns.current_user

    case Enum.find(socket.assigns.notifications, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      %Notification{saved: true} = notification ->
        {:ok, _} = Notification.unsave(notification, actor: user)
        {:noreply, load_notifications(socket)}

      %Notification{} = notification ->
        {:ok, _} = Notification.save(notification, actor: user)
        {:noreply, load_notifications(socket)}
    end
  end

  def handle_event("search", %{"search" => search}, socket) do
    socket
    |> update(:table_params, &%{&1 | search: search})
    |> reset_to_first_page()
  end

  def handle_event("set-filter", %{"filter" => filter}, socket) do
    socket
    |> assign(:filter, parse_filter(filter))
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

  def handle_event("mark-all-read", _params, socket) do
    user = socket.assigns.current_user

    Notification.for_user!(
      Map.put(query_args(socket), :unread_only, true),
      actor: user
    )
    |> case do
      [] ->
        :ok

      unread ->
        Ash.bulk_update!(unread, :mark_read, %{},
          actor: user,
          return_records?: false,
          notify?: true
        )
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

    last_page = max(1, div(page.count + tp.page_size - 1, tp.page_size))

    if tp.page > last_page do
      socket =
        socket
        |> assign(:table_params, %{tp | page: last_page, offset: (last_page - 1) * tp.page_size})
        |> assign_page_search()
        |> load_notifications()

      push_event(socket, "update-url", %{path: inbox_path(socket)})
    else
      assign_notifications(socket, page)
    end
  end

  defp assign_notifications(socket, %Ash.Page.Offset{} = page) do
    pagination = TableParams.apply_pagination(socket.assigns.table_params, page, :notifications)
    unread_count = count(socket, %{unread_only: true})
    now = DateTime.utc_now()

    socket
    |> assign(:notifications, page.results)
    |> assign(:version_changes, NotificationPresenter.version_changes(page.results))
    |> assign(
      :groups,
      NotificationPresenter.group_by_day(page.results, now, socket.assigns.time_zone)
    )
    |> assign(:now, now)
    |> assign(:unread_count, unread_count)
    |> assign(:total_count, count(socket, %{}))
    |> assign(:saved_count, count(socket, %{saved_only: true}))
    |> assign(
      :matching_unread_count,
      count(socket, Map.put(query_args(socket), :unread_only, true))
    )
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
         unread_only: socket.assigns.filter == :unread,
         saved_only: socket.assigns.filter == :saved,
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
      unread_only: socket.assigns.filter == :unread,
      saved_only: socket.assigns.filter == :saved,
      types: if(MapSet.size(active_types) == 0, do: nil, else: MapSet.to_list(active_types)),
      search: tp.search
    }
  end

  defp parse_filter("all"), do: :all
  defp parse_filter("saved"), do: :saved
  defp parse_filter(_filter), do: :unread

  defp parse_types(nil), do: MapSet.new()

  defp parse_types(types) do
    names = String.split(types, ",", trim: true)
    MapSet.new(Enum.filter(NotificationPresenter.type_order(), &(Atom.to_string(&1) in names)))
  end

  defp extra_params(assigns) do
    %{active_types: active_types} = assigns

    %{
      channel_revision_id: assigns.channel_revision_id,
      filter: assigns.filter != :unread && Atom.to_string(assigns.filter),
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
        <div class="ibx-seg" role="group" aria-label="Notification filter">
          <button
            id="filter-unread"
            type="button"
            class={@filter == :unread && "is-active"}
            aria-pressed={to_string(@filter == :unread)}
            phx-click="set-filter"
            phx-value-filter="unread"
          >
            Unread <span class="n">{@unread_count}</span>
          </button>
          <button
            id="filter-all"
            type="button"
            class={@filter == :all && "is-active"}
            aria-pressed={to_string(@filter == :all)}
            phx-click="set-filter"
            phx-value-filter="all"
          >
            All <span class="n">{@total_count}</span>
          </button>
          <button
            id="filter-saved"
            type="button"
            class={@filter == :saved && "is-active"}
            aria-pressed={to_string(@filter == :saved)}
            phx-click="set-filter"
            phx-value-filter="saved"
          >
            Saved <span class="n">{@saved_count}</span>
          </button>
        </div>

        <div class="ibx-actions">
          <button
            id="mark-all-read"
            type="button"
            class="ibx-btn ibx-btn--primary"
            phx-click="mark-all-read"
            disabled={@matching_unread_count == 0}
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

      <p :if={@filter == :saved && @groups == []} id="inbox-saved-empty" class="ibx-empty">
        No saved notifications match these filters.
      </p>

      <p :if={@filter != :saved && @total_count == 0} id="inbox-empty" class="ibx-empty">
        No notifications yet.
      </p>

      <div :if={@filter != :saved && @total_count > 0 && @groups == []} class="ibx-empty">
        Nothing matches these filters.
      </div>

      <div id="inbox-groups">
        <section :for={{{day, rows}, index} <- Enum.with_index(@groups)}>
          <SectionHeader.section_header title={day} count={length(rows)} />
          <RowList.row_list id={"inbox-day-#{index}"}>
            <.row
              :for={n <- rows}
              n={n}
              now={@now}
              time_zone={@time_zone}
              version_changes={@version_changes}
            />
          </RowList.row_list>
        </section>
      </div>

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
        anchor="inbox-groups"
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
  attr :time_zone, :string, required: true

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
          <span
            :if={@n.type == :package_change_opened && @n.change}
            class={"pill pill-#{@n.change.state}"}
          >
            <span class="dot" aria-hidden="true"></span>
            {@n.change.state}
          </span>
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
        <time class="ibx-time" title={NotificationPresenter.clock(@n.occurred_at, @time_zone)}>
          {NotificationPresenter.relative_time(@n.occurred_at, @now)}
        </time>
      </:sublabel>
      <:actions>
        <span :if={is_nil(@n.read_at)} class="ibx-unread-dot" title="Unread"></span>
        <button
          type="button"
          class={["ibx-act", "ibx-save", @n.saved && "is-saved"]}
          phx-click="toggle-saved"
          phx-value-id={@n.id}
          title={if @n.saved, do: "Remove from saved", else: "Save for later"}
          aria-label={if @n.saved, do: "Remove from saved", else: "Save for later"}
          aria-pressed={to_string(@n.saved)}
        >
          <.icon name="saved" />
        </button>
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
    assigns =
      assign(
        assigns,
        :icon_path,
        if(assigns.name == "external",
          do: ~p"/images/external-link.svg",
          else: ~p"/images/#{"inbox-#{assigns.name}.svg"}"
        )
      )

    ~H"""
    <span
      class="svg-icon ibx-icon"
      aria-hidden="true"
      style={"--icon-url: url('#{@icon_path}')"}
    ></span>
    """
  end
end

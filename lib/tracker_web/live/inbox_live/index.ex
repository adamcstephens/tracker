defmodule TrackerWeb.InboxLive.Index do
  use TrackerWeb, :live_view

  on_mount {TrackerWeb.LiveUserAuth, :live_user_required}

  alias Tracker.Notifications.{Inbox, Notification}

  alias TrackerWeb.{
    FeedLink,
    NotificationPresenter,
    PageSearch,
    Pagination,
    RowList,
    SectionHeader,
    TableParams
  }

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    user = FeedLink.ensure_token(socket.assigns.current_user)

    {:ok,
     socket
     |> assign(:current_user, user)
     |> assign(:page_title, "Inbox")
     |> assign(:feed_path, FeedLink.path(user))
     |> assign(:collapsed, MapSet.new())
     |> assign(:search_collapsed, MapSet.new())
     |> assign(:member_limits, %{})}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _url, socket) do
    tp = TableParams.from_params(params, page_size: 25)
    previous_search = Map.get(socket.assigns, :table_params, %TableParams{}).search

    search_collapsed =
      if tp.search == previous_search, do: socket.assigns.search_collapsed, else: MapSet.new()

    {:noreply,
     socket
     |> assign(:channel_revision_id, integer_param(params["channel_revision_id"]))
     |> assign(:channel_id, integer_param(params["channel_id"]))
     |> assign(:table_params, tp)
     |> assign(:search_collapsed, search_collapsed)
     |> assign(:filter, parse_filter(params["filter"]))
     |> assign(:active_types, parse_types(params["types"]))
     |> assign(:lens, socket.assigns.lens && %{socket.assigns.lens | disabled?: true})
     |> assign_page_search()
     |> load_notifications()}
  end

  @impl Phoenix.LiveView
  def handle_event("toggle-read", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.notifications, &(&1.id == String.to_integer(id))) do
      %Notification{read_at: nil} = notification ->
        Notification.mark_read!(notification, actor: socket.assigns.current_user)

      %Notification{} = notification ->
        Notification.mark_unread!(notification, actor: socket.assigns.current_user)

      nil ->
        :ok
    end

    {:noreply, load_notifications(socket)}
  end

  def handle_event("toggle-saved", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.notifications, &(&1.id == String.to_integer(id))) do
      %Notification{saved: true} = notification ->
        Notification.unsave!(notification, actor: socket.assigns.current_user)

      %Notification{} = notification ->
        Notification.save!(notification, actor: socket.assigns.current_user)

      nil ->
        :ok
    end

    {:noreply, load_notifications(socket)}
  end

  def handle_event("search", %{"search" => search}, socket) do
    socket
    |> update(:table_params, &%{&1 | search: search})
    |> assign(:search_collapsed, MapSet.new())
    |> reset_to_first_page()
  end

  def handle_event("set-filter", %{"filter" => filter}, socket) do
    socket |> assign(:filter, parse_filter(filter)) |> reset_to_first_page()
  end

  def handle_event("toggle-type", %{"type" => name}, socket) do
    type = Enum.find(NotificationPresenter.type_order(), &(Atom.to_string(&1) == name))
    active = socket.assigns.active_types

    active =
      if MapSet.member?(active, type),
        do: MapSet.delete(active, type),
        else: MapSet.put(active, type)

    socket |> assign(:active_types, active) |> reset_to_first_page()
  end

  def handle_event("select-all-types", _params, socket) do
    socket
    |> assign(:active_types, MapSet.new(NotificationPresenter.type_order()))
    |> reset_to_first_page()
  end

  def handle_event("clear-types", _params, socket) do
    socket |> assign(:active_types, MapSet.new()) |> reset_to_first_page()
  end

  def handle_event("filter-scope", params, socket) do
    socket
    |> assign(:channel_id, integer_param(params["channel_id"]))
    |> reset_to_first_page()
  end

  def handle_event("reset-filters", _params, socket) do
    socket
    |> assign(:active_types, MapSet.new(NotificationPresenter.type_order()))
    |> assign(:channel_id, nil)
    |> reset_to_first_page()
  end

  def handle_event("toggle-group", %{"id" => id}, socket) do
    key = id
    state = if socket.assigns.table_params.search == "", do: :collapsed, else: :search_collapsed
    keys = Map.fetch!(socket.assigns, state)
    keys = if MapSet.member?(keys, key), do: MapSet.delete(keys, key), else: MapSet.put(keys, key)
    {:noreply, socket |> assign(state, keys) |> load_notifications()}
  end

  def handle_event("show-more", %{"id" => id}, socket) do
    key = id

    {:noreply,
     socket
     |> update(:member_limits, &Map.update(&1, key, 28, fn limit -> limit + 25 end))
     |> load_notifications()}
  end

  def handle_event("show-fewer", %{"id" => id}, socket) do
    key = id
    {:noreply, socket |> update(:member_limits, &Map.delete(&1, key)) |> load_notifications()}
  end

  def handle_event("mark-group-read", %{"id" => id}, socket) do
    {:ok, _count} =
      Inbox.mark_matching_read(query_args(socket), socket.assigns.current_user, entry_key: id)

    {:noreply, load_notifications(socket)}
  end

  def handle_event("mark-all-read", _params, socket) do
    {:ok, _count} = Inbox.mark_matching_read(query_args(socket), socket.assigns.current_user)
    {:noreply, load_notifications(socket)}
  end

  @impl Phoenix.LiveView
  def handle_info(%Ash.Notifier.Notification{resource: Notification}, socket),
    do: {:noreply, load_notifications(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp reset_to_first_page(socket) do
    socket = update(socket, :table_params, &%{&1 | page: 1, offset: 0})
    {:noreply, push_patch(socket, to: inbox_path(socket))}
  end

  defp assign_page_search(socket) do
    tp = socket.assigns.table_params

    assign(socket, :page_search, %PageSearch{
      action: "/inbox",
      value: tp.search,
      placeholder: "Search notifications…",
      hidden: TableParams.to_hidden_inputs(tp, extra_params(socket.assigns)),
      clear_mode: :patch
    })
  end

  defp load_notifications(socket) do
    user = socket.assigns.current_user
    tp = socket.assigns.table_params
    scope = query_args(socket)
    {:ok, page} = Inbox.page(scope, user, offset: tp.offset, limit: tp.page_size)
    last_page = max(1, ceil(page.count / tp.page_size))

    if tp.page > last_page do
      socket =
        assign(socket, :table_params, %{
          tp
          | page: last_page,
            offset: (last_page - 1) * tp.page_size
        })

      socket |> load_notifications() |> push_patch(to: inbox_path(socket), replace: true)
    else
      expanded =
        page.entries
        |> Enum.filter(&expanded?(&1, socket.assigns))
        |> Enum.group_by(&Map.get(socket.assigns.member_limits, &1.key, 3))
        |> Enum.flat_map(fn {limit, entries} ->
          {:ok, loaded} = Inbox.members(scope, user, entries, limit: limit)
          loaded
        end)
        |> Map.new(&{&1.key, &1})

      entries =
        Enum.map(page.entries, fn entry ->
          case Map.fetch(expanded, entry.key) do
            {:ok, loaded} ->
              limit = Map.get(socket.assigns.member_limits, entry.key, 3)
              revisions = Enum.take(loaded.revision_notifications, limit)
              members = Enum.take(loaded.members, limit - length(revisions))

              %{
                loaded
                | revision_notifications: revisions,
                  members: members,
                  propagation_notifications:
                    Enum.take(
                      loaded.propagation_notifications,
                      limit - length(revisions) - length(members)
                    )
              }

            :error ->
              entry
          end
        end)

      notifications =
        Enum.flat_map(entries, fn entry ->
          if entry.kind == :revision,
            do: entry.members ++ entry.revision_notifications ++ entry.propagation_notifications,
            else: [entry.notification]
        end)

      now = DateTime.utc_now()

      groups =
        entries
        |> Enum.chunk_by(
          &NotificationPresenter.day_bucket(
            &1.notification.occurred_at,
            now,
            socket.assigns.time_zone
          )
        )
        |> Enum.map(fn rows ->
          day =
            NotificationPresenter.day_bucket(
              hd(rows).notification.occurred_at,
              now,
              socket.assigns.time_zone
            )

          {day, rows}
        end)

      {:ok, channels} = Inbox.filter_options(user)

      socket
      |> assign(:entries, entries)
      |> assign(:groups, groups)
      |> assign(:notifications, notifications)
      |> assign(:version_changes, NotificationPresenter.version_changes(notifications))
      |> assign(:now, now)
      |> assign(:entry_count, page.count)
      |> assign(:matching_count, page.notification_count)
      |> assign(:matching_unread_count, page.unread_count)
      |> assign(:unread_count, count(socket, %{unread_only: true}))
      |> assign(:total_count, count(socket, %{}))
      |> assign(:saved_count, count(socket, %{saved_only: true}))
      |> assign(:channels, channels)
      |> assign(:has_prev_page?, tp.page > 1)
      |> assign(:has_next_page?, tp.page < last_page)
      |> assign(:total_pages, last_page)
      |> assign(:current_page, tp.page)
      |> assign(
        :narrowed?,
        scope.search != "" or scope.channel_id != nil or
          scope.channel_revision_id != nil or
          length(scope.types) != length(NotificationPresenter.type_order()) or
          socket.assigns.filter == :saved
      )
      |> assign_page_search()
    end
  end

  defp expanded?(%Inbox.Entry{} = entry, assigns) do
    key = entry.key

    entry.kind == :revision and
      if assigns.table_params.search == "",
        do: not MapSet.member?(assigns.collapsed, key),
        else: not MapSet.member?(assigns.search_collapsed, key)
  end

  defp count(socket, args) do
    Notification.for_user!(
      Map.put(args, :channel_revision_id, socket.assigns.channel_revision_id),
      page: [limit: 1, count: true],
      actor: socket.assigns.current_user
    ).count
  end

  defp query_args(socket) do
    %{
      channel_revision_id: socket.assigns.channel_revision_id,
      channel_id: socket.assigns.channel_id,
      unread_only: socket.assigns.filter == :unread,
      saved_only: socket.assigns.filter == :saved,
      types: MapSet.to_list(socket.assigns.active_types),
      search: socket.assigns.table_params.search
    }
  end

  defp integer_param(nil), do: nil
  defp integer_param(""), do: nil

  defp integer_param(value) do
    case Integer.parse(value) do
      {id, ""} -> id
      _ -> nil
    end
  end

  defp parse_filter("all"), do: :all
  defp parse_filter("saved"), do: :saved
  defp parse_filter(_), do: :unread
  defp parse_types(nil), do: MapSet.new(NotificationPresenter.type_order())

  defp parse_types(types) do
    names = String.split(types, ",", trim: true)
    MapSet.new(Enum.filter(NotificationPresenter.type_order(), &(Atom.to_string(&1) in names)))
  end

  defp extra_params(assigns) do
    types =
      cond do
        MapSet.size(assigns.active_types) == 0 -> "none"
        MapSet.size(assigns.active_types) == length(NotificationPresenter.type_order()) -> nil
        true -> assigns.active_types |> Enum.sort() |> Enum.map_join(",", &Atom.to_string/1)
      end

    %{
      channel_revision_id: assigns.channel_revision_id,
      channel_id: assigns.channel_id,
      filter: assigns.filter != :unread && Atom.to_string(assigns.filter),
      types: types
    }
  end

  defp inbox_path(socket),
    do: TableParams.to_path(socket.assigns.table_params, "/inbox", extra_params(socket.assigns))

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="ibx ibx-workspace ibx-grouped">
      <div class="ibx-heading">
        <.view_nav active={:inbox} />
        <a
          :if={@feed_path}
          id="feed-link"
          class="ibx-iconbtn"
          href={@feed_path}
          phx-hook="CopyLink"
          title="Copy your private Atom feed URL"
          aria-label="Copy your private Atom feed URL"
        ><.icon name="rss" /></a>
      </div>
      <div class="ibx-layout">
        <details id="inbox-filters" class="ibx-sidebar" phx-hook="InboxFilters" open>
          <summary>Inbox filters</summary>
          <div class="ibx-sidebar-content">
            <nav class="ibx-view-selection" aria-label="Notification filter">
              <button
                :for={
                  {filter, label, count} <- [
                    {:unread, "Unread", @unread_count},
                    {:all, "All notifications", @total_count},
                    {:saved, "Saved", @saved_count}
                  ]
                }
                id={"filter-#{filter}"}
                type="button"
                class={@filter == filter && "is-active"}
                aria-pressed={to_string(@filter == filter)}
                phx-click="set-filter"
                phx-value-filter={filter}
              >{label}<span class="n">{count}</span></button>
            </nav>
            <fieldset class="ibx-type-selection">
              <legend>Notification types</legend>
              <div class="ibx-type-actions">
                <button id="filter-types-all" type="button" phx-click="select-all-types">Select all</button>
                <button id="filter-types-clear" type="button" phx-click="clear-types">Clear all</button>
              </div>
              <label :for={type <- NotificationPresenter.type_order()}>
                <input
                  id={"filter-type-#{type}"}
                  type="checkbox"
                  checked={MapSet.member?(@active_types, type)}
                  phx-click="toggle-type"
                  phx-value-type={type}
                />
                {NotificationPresenter.type_filter_label(type)}
              </label>
            </fieldset>
            <p :if={MapSet.size(@active_types) == 0} class="ibx-filter-note">
              No notification types selected.
            </p>
            <form id="inbox-scope-filters" phx-change="filter-scope">
              <label for="inbox-channel">Channel</label>
              <select id="inbox-channel" name="channel_id">
                <option value="" selected={is_nil(@channel_id)}>All channels</option>
                <option
                  :for={channel <- @channels}
                  value={channel.id}
                  selected={@channel_id == channel.id}
                >
                  {channel.name}
                </option>
              </select>
            </form>
            <button id="reset-filters" class="ibx-reset" type="button" phx-click="reset-filters">Reset filters</button>
          </div>
        </details>
        <main class="ibx-main">
          <p :if={@channel_revision_id} class="flash flash--info">
            Showing notifications for one revision. <.link navigate={~p"/inbox"}>Show all</.link>
          </p>
          <div class="ibx-results-toolbar">
            <div>
              <strong>{@entry_count} updates</strong><span>{@matching_count} matching notifications</span>
            </div>
            <button
              id="mark-all-read"
              type="button"
              class="ibx-btn ibx-btn--primary"
              phx-click="mark-all-read"
              data-confirm="Mark all notifications matching the current filters as read?"
              disabled={@matching_unread_count == 0}
            >Mark all matching read <span>({@matching_unread_count})</span></button>
          </div>
          <p :if={@groups == []} id="inbox-empty" class="ibx-empty">
            {if @total_count == 0, do: "No notifications yet.", else: "Nothing matches these filters."}
          </p>
          <p :if={@filter == :saved && @groups == []} id="inbox-saved-empty" class="ibx-empty">
            No saved notifications match these filters.
          </p>
          <div id="inbox-groups">
            <section :for={{{day, entries}, index} <- Enum.with_index(@groups)}>
              <SectionHeader.section_header title={day} count={length(entries)} />
              <div class="ibx-day-entries" id={"inbox-day-#{index}"}>
                <%= for entry <- entries do %>
                  <%= if entry.kind == :revision do %>
                    <article
                      id={group_id(entry)}
                      class="ibx-revision-group"
                      data-propagation-count={entry.propagation_count}
                      data-notification-count={entry.notification_count}
                      data-package-count={entry.package_count}
                      data-unread-count={entry.unread_count}
                    >
                      <div class="ibx-group-heading">
                        <button
                          id={"disclosure-#{group_id(entry)}"}
                          type="button"
                          class="ibx-disclosure"
                          phx-click="toggle-group"
                          phx-value-id={entry.key}
                          aria-expanded={to_string(expanded?(entry, assigns))}
                          aria-controls={"members-#{group_id(entry)}"}
                        >
                          <span aria-hidden="true">{if expanded?(entry, assigns),
                            do: "▾",
                            else: "▸"}</span>
                          <span>
                            <strong>{group_title(entry)}</strong>
                            <span class="ibx-group-meta">
                              {entry.package_count} packages<span :if={entry.propagation_count > 0}> | {entry.propagation_count} propagations</span>
                            </span>
                          </span>
                        </button>
                        <button
                          class="ibx-btn"
                          type="button"
                          phx-click="mark-group-read"
                          phx-value-id={entry.key}
                          disabled={entry.unread_count == 0}
                        >{if @narrowed?, do: "Mark matching read", else: "Mark group read"} ({entry.unread_count})</button>
                        <.link
                          navigate={
                            ~p"/channels/#{entry.notification.channel_revision.channel.name}/revisions/#{entry.notification.channel_revision.revision}"
                          }
                          class="ibx-act"
                          aria-label="Open full revision"
                          title="Open full revision"
                        ><.icon name="external" /></.link>
                      </div>
                      <div
                        id={"members-#{group_id(entry)}"}
                        class="ibx-group-members"
                        hidden={!expanded?(entry, assigns)}
                      >
                        <RowList.row_list
                          :if={expanded?(entry, assigns)}
                          id={"notifications-#{group_id(entry)}"}
                        >
                          <.row
                            :for={n <- entry.revision_notifications}
                            n={n}
                            now={@now}
                            time_zone={@time_zone}
                            version_changes={@version_changes}
                          />
                          <.row
                            :for={n <- entry.members}
                            n={n}
                            now={@now}
                            time_zone={@time_zone}
                            version_changes={@version_changes}
                          />
                          <.row
                            :for={n <- entry.propagation_notifications}
                            n={n}
                            now={@now}
                            time_zone={@time_zone}
                            version_changes={@version_changes}
                          />
                        </RowList.row_list>
                        <div :if={expanded?(entry, assigns)} class="ibx-more-controls">
                          <button
                            :if={visible_member_count(entry) < entry.notification_count}
                            class="ibx-reset"
                            type="button"
                            phx-click="show-more"
                            phx-value-id={entry.key}
                          >Show {entry.notification_count - visible_member_count(entry)} more</button>
                          <button
                            :if={Map.get(@member_limits, entry.key, 3) > 3}
                            class="ibx-reset"
                            type="button"
                            phx-click="show-fewer"
                            phx-value-id={entry.key}
                          >Show fewer</button>
                        </div>
                      </div>
                    </article>
                  <% else %>
                    <RowList.row_list id={"standalone-#{entry.notification.id}"}>
                      <.row
                        n={entry.notification}
                        now={@now}
                        time_zone={@time_zone}
                        version_changes={@version_changes}
                      />
                    </RowList.row_list>
                  <% end %>
                <% end %>
              </div>
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
        </main>
      </div>
    </div>
    """
  end

  defp group_id(%Inbox.Entry{kind: :revision} = entry),
    do: "revision-group-#{entry.revision_id}"

  defp group_title(%Inbox.Entry{kind: :revision} = entry) do
    revision = entry.notification.channel_revision
    "#{revision.channel.name} · #{String.slice(revision.revision, 0, 7)}"
  end

  defp visible_member_count(%Inbox.Entry{} = entry),
    do:
      length(entry.members) + length(entry.revision_notifications) +
        length(entry.propagation_notifications)

  attr :active, :atom, required: true, values: [:inbox, :subscriptions]

  def view_nav(assigns) do
    ~H"""
    <nav class="ibx-seg" aria-label="Inbox views">
      <%= for {view, title, path} <- [
        {:inbox, "Inbox", ~p"/inbox"},
        {:subscriptions, "Subscriptions", ~p"/inbox/subscriptions"}
      ] do %>
        <%= if @active == view do %>
          <h1>
            <.link id={"view-nav-#{view}"} navigate={path} class="is-active" aria-current="page">
              {title}
            </.link>
          </h1>
        <% else %>
          <.link id={"view-nav-#{view}"} navigate={path}>{title}</.link>
        <% end %>
      <% end %>
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
      class={["notification-row", if(is_nil(@n.read_at), do: "is-unread", else: "is-read")]}
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

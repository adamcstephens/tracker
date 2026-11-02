defmodule TrackerWeb.DashboardLive.Index do
  use TrackerWeb, :live_view

  alias Tracker.Dashboard
  alias Tracker.Dashboard.ChannelSummary
  alias Tracker.Nixpkgs.{Channel, ChannelRevision, ChangeBranch}
  alias Tracker.Notifications.Notification
  alias TrackerWeb.{ChangeRow, Lens, NotificationPresenter, PageSearch, RowList, Time}

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket) do
      for topic <- [
            "channels:hydra_status_updated",
            "channel_revisions:any:created",
            "channel_revisions:any:completed",
            "channel_revisions:any:options_completed",
            "change_branches:updated"
          ] do
        Phoenix.PubSub.subscribe(Tracker.PubSub, topic)
      end
    end

    {:ok, assign_new(socket, :current_user, fn -> nil end)}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _url, socket) do
    {channel, revision} = Lens.canonical(socket.assigns.lens)
    hidden = if channel, do: %{"channel" => channel}, else: %{}
    hidden = if revision, do: Map.put(hidden, "rev", revision), else: hidden

    {:noreply,
     socket
     |> assign(:page_title, "Welcome")
     |> assign(:page_search, %PageSearch{
       mode: :passthrough,
       action: "/packages",
       placeholder: "Search packages…",
       value: Map.get(params, "search", ""),
       hidden: hidden
     })
     |> load_dashboard()}
  end

  @impl Phoenix.LiveView
  def handle_info(%Ash.Notifier.Notification{resource: Notification, data: notification}, socket) do
    user = socket.assigns.current_user
    {:noreply, refresh_if(socket, user && notification.user_id == user.id)}
  end

  def handle_info(%Ash.Notifier.Notification{resource: Channel, data: channel}, socket) do
    {:noreply, refresh_if(socket, relevant_channel?(socket.assigns.dashboard, channel.id))}
  end

  def handle_info(%Ash.Notifier.Notification{resource: ChannelRevision, data: revision}, socket) do
    {:noreply,
     refresh_if(socket, relevant_channel?(socket.assigns.dashboard, revision.channel_id))}
  end

  def handle_info(%Ash.Notifier.Notification{resource: ChangeBranch, data: branch}, socket) do
    relevant? = Enum.any?(socket.assigns.dashboard.followed, &(&1.change.id == branch.change_id))
    {:noreply, refresh_if(socket, relevant?)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp refresh_if(socket, true), do: load_dashboard(socket)
  defp refresh_if(socket, _irrelevant), do: socket

  defp relevant_channel?(%Dashboard{} = dashboard, channel_id) do
    selected? = dashboard.selected && dashboard.selected.channel.id == channel_id
    selected? || Enum.any?(dashboard.channels, &(&1.channel.id == channel_id))
  end

  defp load_dashboard(socket) do
    dashboard = Dashboard.load(socket.assigns.lens, socket.assigns.current_user)

    socket
    |> assign(:dashboard, dashboard)
    |> assign(:version_changes, NotificationPresenter.version_changes(dashboard.notifications))
    |> assign(:now, DateTime.utc_now())
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div id="dashboard" class="dashboard">
      <h1>Welcome</h1>
      <%= if @dashboard.all? do %>
        <div class="dashboard-columns">
          <div id="dashboard-revision-summary">
            <h2>All channels</h2>
            <p class="dashboard-scope">
              Latest release in each channel · compared with its previous revision
            </p>
            <.channel_summary
              :for={summary <- @dashboard.channels}
              summary={summary}
              time_zone={@time_zone}
            />
            <p :if={@dashboard.channels == []} class="dashboard-empty">
              No releases from the dashboard channels are available yet.
            </p>
          </div>
          <aside>
            <%= if @current_user do %>
              <.inbox
                dashboard={@dashboard}
                version_changes={@version_changes}
                now={@now}
                time_zone={@time_zone}
              />
              <.followed dashboard={@dashboard} time_zone={@time_zone} />
            <% else %>
              <section id="dashboard-recent-changes" class="dashboard-section">
                <div class="dashboard-heading">
                  <h2>Recent changes</h2><.link navigate={~p"/changes"}>View all →</.link>
                </div>
                <ChangeRow.change_row_list id="dashboard-recent-list">
                  <ChangeRow.change_row
                    :for={change <- @dashboard.recent_changes}
                    change={change}
                    time_zone={@time_zone}
                  />
                </ChangeRow.change_row_list>
                <p :if={@dashboard.recent_changes == []} class="dashboard-empty">No changes yet.</p>
              </section>
            <% end %>
          </aside>
        </div>
      <% else %>
        <div id="dashboard-revision-summary">
          <.channel_summary
            :if={@dashboard.selected}
            summary={@dashboard.selected}
            time_zone={@time_zone}
          />
          <p :if={is_nil(@dashboard.selected)} class="dashboard-empty">
            No channel release is available yet.
          </p>
        </div>
        <p :if={is_nil(@current_user)} class="dashboard-scope">
          <.link navigate={~p"/sign-in"}>Sign in</.link> to follow changes and receive updates.
        </p>
        <div class="dashboard-columns">
          <div>
            <.followed :if={@current_user} dashboard={@dashboard} time_zone={@time_zone} />
            <.public_previews :if={@dashboard.selected} summary={@dashboard.selected} />
          </div>
          <aside>
            <.inbox
              :if={@current_user}
              dashboard={@dashboard}
              version_changes={@version_changes}
              now={@now}
              time_zone={@time_zone}
            />
            <section id="dashboard-channels" class="dashboard-section">
              <div class="dashboard-heading">
                <h2>Channels</h2><.link navigate={~p"/channels"}>All channels →</.link>
              </div>
              <div class="dashboard-panel">
                <article :for={summary <- @dashboard.channels} class="dashboard-channel">
                  <.link navigate={
                    Lens.path_for(~p"/channels/#{summary.channel.name}", summary.channel.name)
                  }>{summary.channel.name}</.link>
                  <.badge :if={summary.channel.build_problem?} variant={:danger}>
                    Build problem
                  </.badge>
                  <p :if={summary.revision}>
                    <.link navigate={revision_path(summary)}>{String.slice(
                      summary.revision.revision,
                      0,
                      7
                    )}</.link>
                    · released {Time.format_datetime(summary.revision.released_at, @time_zone)}
                  </p>
                  <p :if={is_nil(summary.revision)}>No releases yet.</p>
                  <p :if={summary.package_counts}>
                    {summary.package_counts.changed} version changes in the latest revision
                  </p>
                </article>
                <p :if={@dashboard.channels == []} class="dashboard-empty">
                  No dashboard channels available yet.
                </p>
              </div>
            </section>
          </aside>
        </div>
      <% end %>
    </div>
    """
  end

  attr :summary, :any, required: true
  attr :time_zone, :string, required: true

  defp channel_summary(assigns) do
    ~H"""
    <section class="dashboard-channel-summary">
      <div class="dashboard-heading dashboard-revision-heading">
        <h3>
          <.link navigate={
            Lens.path_for(~p"/channels/#{@summary.channel.name}", @summary.channel.name)
          }>{@summary.channel.name}</.link>
          <span :if={@summary.revision}> / <.link navigate={revision_path(@summary)}>{String.slice(
            @summary.revision.revision,
            0,
            7
          )}</.link>
          / released {Time.format_datetime(@summary.revision.released_at, @time_zone)}</span>
        </h3>
        <.link :if={@summary.revision} navigate={revision_path(@summary)}>View revision →</.link>
      </div>
      <p :if={@summary.channel.build_problem?} class="dashboard-scope">
        <.badge variant={:danger}>Build problem</.badge>
        Current channel build status
      </p>
      <div class="dashboard-summary-grid">
        <.counts
          summary={@summary}
          title="Packages"
          section="packages"
          counts={@summary.package_counts}
          status={@summary.package_status}
        />
        <.counts
          :if={@summary.option_status != :not_applicable}
          summary={@summary}
          title="Options"
          section="options"
          counts={@summary.option_counts}
          status={@summary.option_status}
        />
      </div>
    </section>
    """
  end

  attr :summary, :any, required: true
  attr :title, :string, required: true
  attr :section, :string, required: true
  attr :counts, :any, required: true
  attr :status, :atom, required: true

  defp counts(assigns) do
    ~H"""
    <section class="dashboard-summary">
      <h3>{@title}</h3>
      <div :if={@counts} class="dashboard-counts">
        <.link
          :for={
            {type, label} <- [
              {:changed, if(@section == "packages", do: "Version changed", else: "Changed")},
              {:added, "Added"},
              {:removed, "Removed"}
            ]
          }
          navigate={comparison_path(@summary, @section, type)}
        >
          <strong>{Map.fetch!(@counts, type)}</strong>{label}
        </.link>
      </div>
      <p :if={is_nil(@counts)} class="dashboard-unavailable">{unavailable(@status)}</p>
    </section>
    """
  end

  attr :dashboard, :any, required: true
  attr :time_zone, :string, required: true

  defp followed(assigns) do
    ~H"""
    <section id="dashboard-followed-changes" class="dashboard-section">
      <div class="dashboard-heading">
        <h2>Changes you’re following</h2><.link navigate={~p"/inbox/subscriptions"}>View all {@dashboard.followed_count} →</.link>
      </div>
      <ChangeRow.change_row_list id="dashboard-followed-list">
        <ChangeRow.change_row
          :for={followed <- @dashboard.followed}
          change={followed.change}
          landed_in={followed.landed_in}
          time_zone={@time_zone}
        />
      </ChangeRow.change_row_list>
      <p :if={@dashboard.followed == []} class="dashboard-empty">
        You’re not following any changes yet.
      </p>
    </section>
    """
  end

  attr :dashboard, :any, required: true
  attr :version_changes, :map, required: true
  attr :now, :any, required: true
  attr :time_zone, :string, required: true

  defp inbox(assigns) do
    ~H"""
    <section id="dashboard-inbox" class="dashboard-section">
      <div class="dashboard-heading">
        <h2>Inbox <span class="pill">{@dashboard.unread_count} unread</span></h2><.link navigate={
          ~p"/inbox"
        }>Open inbox →</.link>
      </div>
      <p class="dashboard-scope">From your subscriptions · all channels</p>
      <RowList.row_list id="dashboard-notifications" stacked>
        <RowList.row
          :for={notification <- @dashboard.notifications}
          id={"notification-#{notification.id}"}
          mode={:plain}
          class={if is_nil(notification.read_at), do: "is-unread", else: "is-read"}
        >
          <:label>
            <.link
              :if={NotificationPresenter.path(notification)}
              navigate={NotificationPresenter.path(notification)}
            >{NotificationPresenter.hero(notification, @version_changes)}</.link>
            <span :if={is_nil(NotificationPresenter.path(notification))}>{NotificationPresenter.hero(
              notification,
              @version_changes
            )}</span>
          </:label>
          <:sublabel>
            <span class="pill ibx-typechip">{NotificationPresenter.type_label(notification.type)}</span>
            <span :if={notification.channel}>{notification.channel.name}</span>
            <span :if={notification.change_branch}>reached {notification.change_branch.branch_name}</span>
          </:sublabel>
          <:meta>
            <time title={NotificationPresenter.clock(notification.occurred_at, @time_zone)}>{NotificationPresenter.relative_time(
              notification.occurred_at,
              @now
            )}</time>
          </:meta>
        </RowList.row>
      </RowList.row_list>
      <p :if={@dashboard.notifications == []} class="dashboard-empty">No notifications yet.</p>
      <p class="dashboard-footer">
        <.link navigate={~p"/inbox/subscriptions"}>Manage subscriptions</.link>
      </p>
    </section>
    """
  end

  attr :summary, :any, required: true

  defp public_previews(assigns) do
    ~H"""
    <section id="dashboard-package-changes" class="dashboard-section">
      <div class="dashboard-heading">
        <h2>Package changes in this channel</h2><.link
          :if={@summary.package_counts}
          navigate={comparison_path(@summary, "packages")}
        >View all →</.link>
      </div>
      <div class="dashboard-panel">
        <article :for={row <- @summary.package_rows} class="dashboard-preview-row">
          <div>
            <.link navigate={
              Lens.path_for(
                ~p"/packages/#{row.attribute}",
                @summary.channel.name,
                @summary.revision.revision
              )
            }>{row.attribute}</.link><p>{row.old_version || "—"} → {row.new_version || "—"}</p>
          </div>
          <span class="comparison-badge">{change_label(row.type, "Version changed")}</span>
        </article>
        <p :if={@summary.package_rows == []} class="dashboard-empty">
          {preview_empty(@summary.package_status, "package")}
        </p>
      </div>
    </section>
    <section
      :if={@summary.option_status != :not_applicable}
      id="dashboard-option-changes"
      class="dashboard-section"
    >
      <div class="dashboard-heading">
        <h2>Option changes in this channel</h2><.link
          :if={@summary.option_counts}
          navigate={comparison_path(@summary, "options")}
        >View all →</.link>
      </div>
      <div class="dashboard-panel">
        <article :for={row <- @summary.option_rows} class="dashboard-preview-row">
          <div>
            <.link navigate={
              Lens.path_for(
                ~p"/options/#{row.name}",
                @summary.channel.name,
                @summary.revision.revision
              )
            }>{row.name}</.link>
            <p :for={field <- row.fields}>
              {field.field}: {metadata(field.old)} → {metadata(field.new)}
            </p>
            <p :if={row.fields == []}>
              {if row.type == :added,
                do: "Option added in this revision",
                else: "Option removed from this revision"}
            </p>
          </div>
          <span class="comparison-badge">{change_label(row.type, "Changed")}</span>
        </article>
        <p :if={@summary.option_rows == []} class="dashboard-empty">
          {preview_empty(@summary.option_status, "option")}
        </p>
      </div>
    </section>
    """
  end

  defp revision_path(%ChannelSummary{} = summary) do
    Lens.path_for(
      ~p"/channels/#{summary.channel.name}/revisions/#{summary.revision.revision}",
      summary.channel.name,
      summary.revision.revision
    )
  end

  defp comparison_path(summary, section, type \\ nil) do
    path = revision_path(summary)
    uri = URI.parse(path)
    query = URI.decode_query(uri.query || "")
    key = if section == "packages", do: "change", else: "option_change"
    query = if type, do: Map.put(query, key, Atom.to_string(type)), else: query
    URI.to_string(%{uri | query: URI.encode_query(query), fragment: section})
  end

  defp unavailable(:no_release), do: "No releases yet."
  defp unavailable(:first_revision), do: "First known revision; no predecessor to compare."
  defp unavailable(:incomplete), do: "Comparison unavailable until ingestion completes."
  defp preview_empty(:ready, kind), do: "No #{kind} changes in this revision."
  defp preview_empty(status, _kind), do: unavailable(status)
  defp change_label(:changed, label), do: label
  defp change_label(:added, _label), do: "Added"
  defp change_label(:removed, _label), do: "Removed"
  defp metadata(nil), do: "—"
  defp metadata(value) when is_binary(value), do: String.slice(value, 0, 160)
  defp metadata(value), do: inspect(value, limit: 5, printable_limit: 160)
end

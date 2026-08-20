defmodule TrackerWeb.MaintainerLive.Show do
  use TrackerWeb, :live_view

  alias TrackerWeb.PageSearch
  alias TrackerWeb.Pagination
  alias TrackerWeb.RowList
  alias TrackerWeb.SectionHeader
  alias TrackerWeb.TableParams

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      {@maintainer.github}
      <:subtitle>Maintainer</:subtitle>
    </.header>

    <.list>
      <:item :if={@maintainer.github} title="GitHub">
        <a
          href={"https://github.com/#{@maintainer.github}"}
          target="_blank"
          rel="noopener noreferrer"
        >
          {@maintainer.github}
        </a>
      </:item>
    </.list>

    <div :if={@maintainer.teams != []}>
      <SectionHeader.section_header title="Teams" count={length(@maintainer.teams)} />
      <RowList.row_list id="maintainer-teams" reserve_sublabel>
        <RowList.row
          :for={t <- @maintainer.teams}
          mode={:link}
          navigate={~p"/teams/#{t.short_name}"}
        >
          <:label>{t.short_name}</:label>
          <:sublabel :if={t.scope}>{t.scope}</:sublabel>
          <:actions><span class="arrow" aria-hidden="true">→</span></:actions>
        </RowList.row>
      </RowList.row_list>
    </div>

    <section :if={@recent_changes != []}>
      <SectionHeader.section_header title="Recent Changes" count={length(@recent_changes)} />
      <RowList.row_list id="maintainer-recent-changes" stacked>
        <RowList.row
          :for={change <- @recent_changes}
          mode={:link}
          navigate={~p"/changes/#{change.number}"}
        >
          <:label>
            <span class="row-num">#{change.number}</span> {change.title}
          </:label>
          <:meta>
            <span>{change_role(change, @maintainer.github_id)}</span>
            <span>{format_datetime(change.merged_at)}</span>
          </:meta>
        </RowList.row>
      </RowList.row_list>
    </section>

    <SectionHeader.section_header title="Packages" count={@package_count}>
      <:controls>
        <form
          id="maintainer-package-search"
          method="get"
          action={~p"/maintainers/#{@maintainer.github}"}
          phx-change="search-packages"
          phx-submit="search-packages"
        >
          <input
            type="search"
            name="package_search"
            value={@table_params.search}
            placeholder="Filter packages..."
            phx-debounce="300"
          />
        </form>
      </:controls>
    </SectionHeader.section_header>

    <RowList.row_list id="maintainer-packages" phx-update="stream">
      <RowList.row
        :for={{dom_id, package} <- @streams.packages}
        id={dom_id}
        mode={:link}
        navigate={~p"/packages/#{package.attribute}"}
      >
        <:label>{package.attribute}</:label>
        <:actions><span class="arrow" aria-hidden="true">→</span></:actions>
      </RowList.row>
    </RowList.row_list>

    <Pagination.controls
      total_pages={@total_pages}
      current_page={@current_page}
      has_prev_page?={@has_prev_page?}
      has_next_page?={@has_next_page?}
      prev_path={
        TableParams.page_path(
          @table_params,
          @current_page - 1,
          "/maintainers/#{@maintainer.github}"
        )
      }
      next_path={
        TableParams.page_path(
          @table_params,
          @current_page + 1,
          "/maintainers/#{@maintainer.github}"
        )
      }
    />
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Tracker.PubSub, "changes:updated")
    end

    {:ok, assign_new(socket, :current_user, fn -> nil end)}
  end

  @impl true
  def handle_info(%Ash.Notifier.Notification{resource: Tracker.Nixpkgs.Change}, socket) do
    {:noreply, reload_page_data(socket)}
  end

  @impl true
  def handle_params(%{"github" => github} = params, _url, socket) do
    maintainer = Tracker.Nixpkgs.Maintainer.get_by_github!(github, load: [:teams])

    tp = TableParams.from_params(params, search_key: :package_search)

    {:noreply,
     socket
     |> assign(:page_title, maintainer.github)
     |> assign(:maintainer, maintainer)
     |> assign(:table_params, tp)
     |> assign(:page_search, %PageSearch{
       mode: :passthrough,
       action: "/maintainers",
       value: Map.get(params, "search", "")
     })
     |> reload_page_data()}
  end

  @impl true
  def handle_event("search-packages", %{"package_search" => search}, socket) do
    tp = %{socket.assigns.table_params | search: search, page: 1, offset: 0}

    {:noreply,
     push_patch(socket,
       to: TableParams.to_path(tp, "/maintainers/#{socket.assigns.maintainer.github}")
     )}
  end

  @impl true
  def handle_event("next-page", _params, socket) do
    tp = socket.assigns.table_params

    {:noreply,
     push_patch(socket,
       to:
         TableParams.to_path(
           %{tp | page: tp.page + 1},
           "/maintainers/#{socket.assigns.maintainer.github}"
         )
     )}
  end

  @impl true
  def handle_event("prev-page", _params, socket) do
    tp = socket.assigns.table_params

    {:noreply,
     push_patch(socket,
       to:
         TableParams.to_path(
           %{tp | page: max(tp.page - 1, 1)},
           "/maintainers/#{socket.assigns.maintainer.github}"
         )
     )}
  end

  defp format_datetime(nil), do: "-"
  defp format_datetime(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  defp change_role(change, github_id) do
    cond do
      change.author_github_id == github_id and change.merged_by_github_id == github_id ->
        "author & merger"

      change.author_github_id == github_id ->
        "author"

      change.merged_by_github_id == github_id ->
        "merger"

      true ->
        ""
    end
  end

  defp reload_page_data(socket) do
    maintainer = socket.assigns.maintainer
    tp = socket.assigns.table_params
    channel_id = TrackerWeb.Lens.channel_id(socket.assigns.lens)
    channel_name = TrackerWeb.Lens.channel_name(socket.assigns.lens)

    recent_changes =
      Tracker.Nixpkgs.Change.by_maintainer_github_id!(maintainer.github_id, channel_name,
        page: [limit: 10]
      ).results

    packages =
      Tracker.Nixpkgs.Package.by_maintainer!(maintainer.id, tp.search, channel_id,
        page: [offset: tp.offset, limit: 15, count: true]
      )

    pagination = TableParams.apply_pagination(tp, packages, :packages)

    socket
    |> assign(:recent_changes, recent_changes)
    |> stream(:packages, pagination.stream_results, reset: true)
    |> assign(:has_prev_page?, pagination.has_prev_page?)
    |> assign(:has_next_page?, pagination.has_next_page?)
    |> assign(:total_pages, pagination.total_pages)
    |> assign(:current_page, pagination.current_page)
    |> assign(:package_count, packages.count)
  end
end

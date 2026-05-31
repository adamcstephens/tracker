defmodule TrackerWeb.MaintainerLive.Show do
  use TrackerWeb, :live_view

  alias TrackerWeb.DataTable
  alias TrackerWeb.PageSearch
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

    <div :if={@maintainer.teams != []} style="margin-top: 1rem;">
      <h2>Teams</h2>
      <ul>
        <li :for={t <- @maintainer.teams}>
          <.link navigate={~p"/teams/#{t.short_name}"}>{t.short_name}</.link>
          <span :if={t.scope}>{t.scope}</span>
        </li>
      </ul>
    </div>

    <section :if={@recent_changes != []}>
      <h2>Recent Changes</h2>
      <figure>
        <table role="grid">
          <thead>
            <tr>
              <th>#</th>
              <th>Title</th>
              <th>Role</th>
              <th>Merged</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={change <- @recent_changes}>
              <td>
                <.link navigate={~p"/changes/#{change.number}"}>{change.number}</.link>
              </td>
              <td>
                <span style="display: block; max-width: 40ch; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
                  {change.title}
                </span>
              </td>
              <td>{change_role(change, @maintainer.github_id)}</td>
              <td>{format_datetime(change.merged_at)}</td>
            </tr>
          </tbody>
        </table>
      </figure>
    </section>

    <h2>Packages ({@package_count})</h2>

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

    <.table
      id="maintainer-packages"
      rows={@streams.packages}
      row_click={fn {_id, package} -> JS.navigate(~p"/packages/#{package.attribute}") end}
    >
      <:col :let={{_id, package}} label="Package">{package.attribute}</:col>
    </.table>

    <DataTable.pagination
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

  def handle_info({:set_lens, channel_name, rev}, socket) do
    socket = TrackerWeb.LensHandlers.handle_lens_change(socket, channel_name, rev)
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

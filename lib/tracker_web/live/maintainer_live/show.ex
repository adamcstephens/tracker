defmodule TrackerWeb.MaintainerLive.Show do
  use TrackerWeb, :live_view

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

    <form phx-change="search" phx-submit="search">
      <input
        type="search"
        name="search"
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

    <nav
      :if={@total_pages > 1}
      style="display: flex; align-items: center; justify-content: center; gap: 0.5rem; margin-top: 1rem;"
    >
      <.button
        class="outline secondary"
        style="padding: 0.25rem 0.75rem; font-size: 0.875rem;"
        phx-click="prev-page"
        disabled={!@has_prev_page?}
      >
        &larr;
      </.button>
      <small>
        Page {@current_page} of {@total_pages}
      </small>
      <.button
        class="outline secondary"
        style="padding: 0.25rem 0.75rem; font-size: 0.875rem;"
        phx-click="next-page"
        disabled={!@has_next_page?}
      >
        &rarr;
      </.button>
    </nav>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Tracker.PubSub, "changes")
    end

    {:ok, assign_new(socket, :current_user, fn -> nil end)}
  end

  @impl true
  def handle_info({:change_processed, _payload}, socket) do
    {:noreply,
     assign(socket, :recent_changes, load_recent_changes(socket.assigns.maintainer.github_id))}
  end

  def handle_info({:set_lens, channel_name, rev}, socket) do
    {:noreply, TrackerWeb.LensHandlers.handle_lens_change(socket, channel_name, rev)}
  end

  @impl true
  def handle_params(%{"github" => github} = params, _url, socket) do
    maintainer = Tracker.Nixpkgs.Maintainer.get_by_github!(github, load: [:teams])
    recent_changes = load_recent_changes(maintainer.github_id)

    tp = TableParams.from_params(params)
    packages = load_packages(maintainer.id, tp.search, tp.offset)
    pagination = TableParams.apply_pagination(tp, packages, :packages)

    {:noreply,
     socket
     |> assign(:page_title, maintainer.github)
     |> assign(:maintainer, maintainer)
     |> assign(:recent_changes, recent_changes)
     |> assign(:table_params, tp)
     |> stream(:packages, pagination.stream_results, reset: true)
     |> assign(:has_prev_page?, pagination.has_prev_page?)
     |> assign(:has_next_page?, pagination.has_next_page?)
     |> assign(:total_pages, pagination.total_pages)
     |> assign(:current_page, pagination.current_page)
     |> assign(:package_count, packages.count)}
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
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

  defp load_recent_changes(github_id) do
    Tracker.Nixpkgs.Change.by_maintainer_github_id!(github_id, page: [limit: 10]).results
  end

  defp load_packages(maintainer_id, search, offset) do
    Tracker.Nixpkgs.Package.by_maintainer!(maintainer_id, search,
      page: [offset: offset, limit: 15, count: true]
    )
  end
end

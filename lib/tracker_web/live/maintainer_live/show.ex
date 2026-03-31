defmodule TrackerWeb.MaintainerLive.Show do
  use TrackerWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      {@maintainer.name || @maintainer.github}
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
      <:item :if={@maintainer.email} title="Email">{@maintainer.email}</:item>
      <:item :if={@maintainer.matrix} title="Matrix">{@maintainer.matrix}</:item>
    </.list>

    <div :if={@maintainer.teams != []} style="margin-top: 1rem;">
      <h2>Teams</h2>
      <ul>
        <li :for={t <- @maintainer.teams}>
          <.link navigate={~p"/teams/#{t.short_name}"}>{t.short_name}</.link>
          <span :if={t.scope}> —        {t.scope}</span>
        </li>
      </ul>
    </div>

    <h2>Packages ({@package_count})</h2>

    <form phx-change="search" phx-submit="search">
      <input
        type="search"
        name="search"
        value={@search}
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

    <.back navigate={~p"/maintainers"}>Back to maintainers</.back>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_new(socket, :current_user, fn -> nil end)}
  end

  @impl true
  def handle_params(%{"github" => github} = params, _url, socket) do
    maintainer = Tracker.Nixpkgs.Maintainer.get_by_github!(github, load: [:teams])

    search = Map.get(params, "search", "")
    page = params |> Map.get("page", "1") |> String.to_integer() |> max(1)
    offset = (page - 1) * 15

    packages = load_packages(maintainer.id, search, offset)
    total_pages = ceil(packages.count / 15)

    {:noreply,
     socket
     |> assign(:page_title, maintainer.name || maintainer.github)
     |> assign(:maintainer, maintainer)
     |> assign(:search, search)
     |> stream(:packages, packages.results, reset: true)
     |> assign(:has_prev_page?, offset > 0)
     |> assign(:has_next_page?, packages.more?)
     |> assign(:total_pages, total_pages)
     |> assign(:current_page, div(offset, 15) + 1)
     |> assign(:package_count, packages.count)}
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    {:noreply,
     push_patch(socket,
       to: show_path(socket.assigns.maintainer.github, search, 1)
     )}
  end

  @impl true
  def handle_event("next-page", _params, socket) do
    {:noreply,
     push_patch(socket,
       to:
         show_path(
           socket.assigns.maintainer.github,
           socket.assigns.search,
           socket.assigns.current_page + 1
         )
     )}
  end

  @impl true
  def handle_event("prev-page", _params, socket) do
    {:noreply,
     push_patch(socket,
       to:
         show_path(
           socket.assigns.maintainer.github,
           socket.assigns.search,
           max(socket.assigns.current_page - 1, 1)
         )
     )}
  end

  defp load_packages(maintainer_id, search, offset) do
    Tracker.Nixpkgs.Package.by_maintainer!(maintainer_id, search,
      page: [offset: offset, limit: 15, count: true]
    )
  end

  defp show_path(github, search, page) do
    params =
      %{}
      |> then(fn p -> if search != "", do: Map.put(p, :search, search), else: p end)
      |> then(fn p -> if page > 1, do: Map.put(p, :page, page), else: p end)

    case URI.encode_query(params) do
      "" -> "/maintainers/#{github}"
      qs -> "/maintainers/#{github}?#{qs}"
    end
  end
end

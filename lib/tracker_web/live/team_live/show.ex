defmodule TrackerWeb.TeamLive.Show do
  use TrackerWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      {@team.short_name}
      <:subtitle>{@team.scope}</:subtitle>
    </.header>

    <.list>
      <:item :if={@team.github} title="GitHub">
        <a
          href={"https://github.com/orgs/NixOS/teams/#{@team.github}"}
          target="_blank"
          rel="noopener noreferrer"
        >
          {@team.github}
        </a>
      </:item>
    </.list>

    <div :if={@team.members != []} style="margin-top: 1rem;">
      <h2>Members</h2>
      <ul>
        <li :for={m <- @team.members}>
          <.link navigate={~p"/maintainers/#{m.github}"}>{m.name || m.github}</.link>
        </li>
      </ul>
    </div>

    <h2>Packages</h2>

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
      id="team-packages"
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

    <.back navigate={~p"/teams"}>Back to teams</.back>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_new(socket, :current_user, fn -> nil end)}
  end

  @impl true
  def handle_params(%{"short_name" => short_name} = params, _url, socket) do
    team = Tracker.Nixpkgs.Team.get_by_short_name!(short_name, load: [:members])

    search = Map.get(params, "search", "")
    page = params |> Map.get("page", "1") |> String.to_integer() |> max(1)
    offset = (page - 1) * 15

    packages = load_packages(team.id, search, offset)
    total_pages = ceil(packages.count / 15)

    {:noreply,
     socket
     |> assign(:page_title, team.short_name)
     |> assign(:team, team)
     |> assign(:search, search)
     |> stream(:packages, packages.results, reset: true)
     |> assign(:has_prev_page?, offset > 0)
     |> assign(:has_next_page?, packages.more?)
     |> assign(:total_pages, total_pages)
     |> assign(:current_page, div(offset, 15) + 1)}
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    {:noreply,
     push_patch(socket,
       to: show_path(socket.assigns.team.short_name, search, 1)
     )}
  end

  @impl true
  def handle_event("next-page", _params, socket) do
    {:noreply,
     push_patch(socket,
       to:
         show_path(
           socket.assigns.team.short_name,
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
           socket.assigns.team.short_name,
           socket.assigns.search,
           max(socket.assigns.current_page - 1, 1)
         )
     )}
  end

  defp load_packages(team_id, search, offset) do
    Tracker.Nixpkgs.Package.by_team!(team_id, search,
      page: [offset: offset, limit: 15, count: true]
    )
  end

  defp show_path(short_name, search, page) do
    params =
      %{}
      |> then(fn p -> if search != "", do: Map.put(p, :search, search), else: p end)
      |> then(fn p -> if page > 1, do: Map.put(p, :page, page), else: p end)

    case URI.encode_query(params) do
      "" -> "/teams/#{short_name}"
      qs -> "/teams/#{short_name}?#{qs}"
    end
  end
end

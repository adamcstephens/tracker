defmodule TrackerWeb.TeamLive.Show do
  use TrackerWeb, :live_view

  alias TrackerWeb.TableParams

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
          <.link navigate={~p"/maintainers/#{m.github}"}>{m.github}</.link>
        </li>
      </ul>
    </div>

    <h2>Packages</h2>

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
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_new(socket, :current_user, fn -> nil end)}
  end

  @impl true
  def handle_params(%{"short_name" => short_name} = params, _url, socket) do
    team = Tracker.Nixpkgs.Team.get_by_short_name!(short_name, load: [:members])

    tp = TableParams.from_params(params)
    packages = load_packages(team.id, tp.search, tp.offset)
    pagination = TableParams.apply_pagination(tp, packages, :packages)

    {:noreply,
     socket
     |> assign(:page_title, team.short_name)
     |> assign(:team, team)
     |> assign(:table_params, tp)
     |> stream(:packages, pagination.stream_results, reset: true)
     |> assign(:has_prev_page?, pagination.has_prev_page?)
     |> assign(:has_next_page?, pagination.has_next_page?)
     |> assign(:total_pages, pagination.total_pages)
     |> assign(:current_page, pagination.current_page)}
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    tp = %{socket.assigns.table_params | search: search, page: 1, offset: 0}

    {:noreply,
     push_patch(socket,
       to: TableParams.to_path(tp, "/teams/#{socket.assigns.team.short_name}")
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
           "/teams/#{socket.assigns.team.short_name}"
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
           "/teams/#{socket.assigns.team.short_name}"
         )
     )}
  end

  defp load_packages(team_id, search, offset) do
    Tracker.Nixpkgs.Package.by_team!(team_id, search,
      page: [offset: offset, limit: 15, count: true]
    )
  end

  @impl true
  def handle_info({:set_lens, channel_name, rev}, socket) do
    {:noreply, TrackerWeb.LensHandlers.handle_lens_change(socket, channel_name, rev)}
  end
end

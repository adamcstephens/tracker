defmodule TrackerWeb.TeamLive.Show do
  use TrackerWeb, :live_view

  alias TrackerWeb.DataTable
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

    <DataTable.pagination
      total_pages={@total_pages}
      current_page={@current_page}
      has_prev_page?={@has_prev_page?}
      has_next_page?={@has_next_page?}
    />
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

    {:noreply,
     socket
     |> assign(:page_title, team.short_name)
     |> assign(:team, team)
     |> assign(:table_params, tp)
     |> reload_packages()}
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

  defp reload_packages(socket) do
    tp = socket.assigns.table_params
    channel_id = socket.assigns.lens && socket.assigns.lens.channel.id

    packages =
      Tracker.Nixpkgs.Package.by_team!(socket.assigns.team.id, tp.search, channel_id,
        page: [offset: tp.offset, limit: 15, count: true]
      )

    pagination = TableParams.apply_pagination(tp, packages, :packages)

    socket
    |> stream(:packages, pagination.stream_results, reset: true)
    |> assign(:has_prev_page?, pagination.has_prev_page?)
    |> assign(:has_next_page?, pagination.has_next_page?)
    |> assign(:total_pages, pagination.total_pages)
    |> assign(:current_page, pagination.current_page)
  end

  @impl true
  def handle_info({:set_lens, channel_name, rev}, socket) do
    socket = TrackerWeb.LensHandlers.handle_lens_change(socket, channel_name, rev)
    {:noreply, reload_packages(socket)}
  end
end

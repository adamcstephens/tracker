defmodule TrackerWeb.ChangeLive.Index do
  use TrackerWeb, :live_view

  @valid_sort_fields ~w(number title author base_ref merged_at)a
  @default_sort_by :number
  @default_sort_dir :desc

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Changes
    </.header>

    <form phx-change="search" phx-submit="search" id="change-search" phx-hook="UpdateURL">
      <input
        type="search"
        name="search"
        value={@search}
        placeholder="Search changes..."
        phx-debounce="300"
      />
    </form>

    <figure>
      <table role="grid">
        <thead>
          <tr>
            <.sort_header field={:number} label="#" sort_by={@sort_by} sort_dir={@sort_dir} />
            <.sort_header field={:title} label="Title" sort_by={@sort_by} sort_dir={@sort_dir} />
            <.sort_header field={:author} label="Author" sort_by={@sort_by} sort_dir={@sort_dir} />
            <.sort_header
              field={:base_ref}
              label="Base"
              sort_by={@sort_by}
              sort_dir={@sort_dir}
            />
            <.sort_header
              field={:merged_at}
              label="Merged"
              sort_by={@sort_by}
              sort_dir={@sort_dir}
            />
          </tr>
        </thead>
        <tbody id="changes" phx-update="stream">
          <tr :for={{id, change} <- @streams.changes} id={id}>
            <td>
              <.link navigate={~p"/changes/#{change.number}"}>{change.number}</.link>
            </td>
            <td>
              <.link navigate={~p"/changes/#{change.number}"}>
                <span style="display: block; max-width: 50ch; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
                  {change.title}
                </span>
              </.link>
            </td>
            <td>{change.author}</td>
            <td>{change.base_ref}</td>
            <td>{format_datetime(change.merged_at)}</td>
          </tr>
        </tbody>
      </table>
    </figure>

    <nav style="display: flex; align-items: center; justify-content: center; gap: 0.5rem; margin-top: 1rem;">
      <.button
        class="outline secondary"
        style="padding: 0.25rem 0.75rem; font-size: 0.875rem;"
        phx-click="prev-page"
        disabled={!@has_prev_page?}
      >
        &larr;
      </.button>
      <small :if={@total_pages > 0}>
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

  defp sort_header(assigns) do
    ~H"""
    <th phx-click="sort" phx-value-field={@field} style="cursor: pointer">
      {@label} {sort_indicator(@sort_by, @sort_dir, @field)}
    </th>
    """
  end

  defp sort_indicator(sort_by, :asc, field) when sort_by == field, do: "↑"
  defp sort_indicator(sort_by, :desc, field) when sort_by == field, do: "↓"
  defp sort_indicator(_, _, _), do: ""

  defp format_datetime(nil), do: "-"
  defp format_datetime(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_new(socket, :current_user, fn -> nil end)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    search = Map.get(params, "search", "")
    sort_by = parse_sort_by(params["sort_by"])
    sort_dir = parse_sort_dir(params["sort_dir"])
    page = params |> Map.get("page", "1") |> String.to_integer() |> max(1)
    offset = (page - 1) * 15

    socket =
      socket
      |> assign(:page_title, "Changes")
      |> assign(:search, search)
      |> assign(:sort_by, sort_by)
      |> assign(:sort_dir, sort_dir)
      |> assign(:offset, offset)
      |> load_changes()

    {:noreply, socket}
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    socket =
      socket
      |> assign(:search, search)
      |> assign(:offset, 0)
      |> load_changes()
      |> push_event("update-url", %{
        path: changes_path(search, socket.assigns.sort_by, socket.assigns.sort_dir, 1)
      })

    {:noreply, socket}
  end

  @impl true
  def handle_event("sort", %{"field" => field}, socket) do
    new_sort_by = parse_sort_by(field)

    new_sort_dir =
      if socket.assigns.sort_by == new_sort_by do
        toggle_dir(socket.assigns.sort_dir)
      else
        :asc
      end

    {:noreply,
     push_patch(socket,
       to: changes_path(socket.assigns.search, new_sort_by, new_sort_dir, 1)
     )}
  end

  @impl true
  def handle_event("next-page", _params, socket) do
    {:noreply,
     push_patch(socket,
       to:
         changes_path(
           socket.assigns.search,
           socket.assigns.sort_by,
           socket.assigns.sort_dir,
           socket.assigns.current_page + 1
         )
     )}
  end

  @impl true
  def handle_event("prev-page", _params, socket) do
    {:noreply,
     push_patch(socket,
       to:
         changes_path(
           socket.assigns.search,
           socket.assigns.sort_by,
           socket.assigns.sort_dir,
           max(socket.assigns.current_page - 1, 1)
         )
     )}
  end

  defp changes_path(search, sort_by, sort_dir, page) do
    params =
      %{}
      |> then(fn p -> if search != "", do: Map.put(p, :search, search), else: p end)
      |> then(fn p ->
        if sort_by != @default_sort_by, do: Map.put(p, :sort_by, sort_by), else: p
      end)
      |> then(fn p ->
        if sort_dir != @default_sort_dir, do: Map.put(p, :sort_dir, sort_dir), else: p
      end)
      |> then(fn p -> if page > 1, do: Map.put(p, :page, page), else: p end)

    case URI.encode_query(params) do
      "" -> "/changes"
      qs -> "/changes?#{qs}"
    end
  end

  defp load_changes(socket) do
    %{search: search, sort_by: sort_by, sort_dir: sort_dir, offset: offset} = socket.assigns

    page =
      Tracker.Nixpkgs.Change.list!(search,
        actor: socket.assigns[:current_user],
        query: [sort: [{sort_by, sort_dir}]],
        page: [offset: offset, count: true]
      )

    total_pages = if page.count > 0, do: ceil(page.count / 15), else: 0
    current_page = div(offset, 15) + 1

    socket
    |> stream(:changes, page.results, reset: true)
    |> assign(:has_prev_page?, offset > 0)
    |> assign(:has_next_page?, page.more?)
    |> assign(:total_pages, total_pages)
    |> assign(:current_page, current_page)
  end

  defp parse_sort_by(nil), do: @default_sort_by

  defp parse_sort_by(field) do
    atom = String.to_existing_atom(field)
    if atom in @valid_sort_fields, do: atom, else: @default_sort_by
  rescue
    ArgumentError -> @default_sort_by
  end

  defp parse_sort_dir("asc"), do: :asc
  defp parse_sort_dir(_), do: @default_sort_dir

  defp toggle_dir(:asc), do: :desc
  defp toggle_dir(:desc), do: :asc
end

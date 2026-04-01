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

    <form
      phx-change="filter"
      phx-submit="filter"
      id="change-filters"
      phx-hook="UpdateURL"
      style="display: flex; gap: 0.5rem; align-items: end; margin-bottom: 1rem;"
    >
      <input
        type="search"
        name="search"
        value={@search}
        placeholder="Search title or author..."
        phx-debounce="300"
        style="flex: 3;"
      />
      <select name="base_ref" aria-label="Filter by base branch" style="flex: 1;">
        <option value="">All branches</option>
        <option :for={base <- @base_refs} value={base} selected={base == @base_ref_filter}>
          {base}
        </option>
      </select>
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
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Tracker.PubSub, "changes")
    end

    base_refs = load_base_refs()
    {:ok, socket |> assign_new(:current_user, fn -> nil end) |> assign(:base_refs, base_refs)}
  end

  @impl true
  def handle_info({:change_processed, _payload}, socket) do
    {:noreply, socket |> assign(:base_refs, load_base_refs()) |> load_changes()}
  end

  @impl true
  def handle_params(params, _url, socket) do
    search = Map.get(params, "search", "")
    base_ref_filter = Map.get(params, "base_ref", "")
    sort_by = parse_sort_by(params["sort_by"])
    sort_dir = parse_sort_dir(params["sort_dir"])
    page = params |> Map.get("page", "1") |> String.to_integer() |> max(1)
    offset = (page - 1) * 15

    socket =
      socket
      |> assign(:page_title, "Changes")
      |> assign(:search, search)
      |> assign(:base_ref_filter, base_ref_filter)
      |> assign(:sort_by, sort_by)
      |> assign(:sort_dir, sort_dir)
      |> assign(:offset, offset)
      |> load_changes()

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter", params, socket) do
    search = Map.get(params, "search", "")
    base_ref = Map.get(params, "base_ref", "")

    socket =
      socket
      |> assign(:search, search)
      |> assign(:base_ref_filter, base_ref)
      |> assign(:offset, 0)
      |> load_changes()
      |> push_event("update-url", %{
        path: changes_path(socket.assigns, search: search, base_ref: base_ref, page: 1)
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
       to: changes_path(socket.assigns, sort_by: new_sort_by, sort_dir: new_sort_dir, page: 1)
     )}
  end

  @impl true
  def handle_event("next-page", _params, socket) do
    {:noreply,
     push_patch(socket,
       to: changes_path(socket.assigns, page: socket.assigns.current_page + 1)
     )}
  end

  @impl true
  def handle_event("prev-page", _params, socket) do
    {:noreply,
     push_patch(socket,
       to: changes_path(socket.assigns, page: max(socket.assigns.current_page - 1, 1))
     )}
  end

  defp changes_path(assigns, overrides) do
    search = Keyword.get(overrides, :search, assigns.search)
    base_ref = Keyword.get(overrides, :base_ref, assigns.base_ref_filter)
    sort_by = Keyword.get(overrides, :sort_by, assigns.sort_by)
    sort_dir = Keyword.get(overrides, :sort_dir, assigns.sort_dir)
    page = Keyword.get(overrides, :page, assigns.current_page)

    params =
      %{}
      |> then(fn p -> if search != "", do: Map.put(p, :search, search), else: p end)
      |> then(fn p -> if base_ref != "", do: Map.put(p, :base_ref, base_ref), else: p end)
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
    %{
      search: search,
      base_ref_filter: base_ref,
      sort_by: sort_by,
      sort_dir: sort_dir,
      offset: offset
    } = socket.assigns

    page =
      Tracker.Nixpkgs.Change.list!(search, base_ref,
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

  defp load_base_refs do
    Tracker.Nixpkgs.Change.distinct_base_refs!()
    |> Enum.map(& &1.base_ref)
    |> Enum.reject(&is_nil/1)
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

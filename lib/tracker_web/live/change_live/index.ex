defmodule TrackerWeb.ChangeLive.Index do
  use TrackerWeb, :live_view

  alias TrackerWeb.TableParams

  @table_opts [
    allowed_sorts: ~w(number title author base_ref merged_at)a,
    default_sort: :number,
    default_sort_dir: :desc
  ]

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
        value={@table_params.search}
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
            <.sort_header field={:number} label="#" table_params={@table_params} />
            <.sort_header field={:title} label="Title" table_params={@table_params} />
            <.sort_header field={:author} label="Author" table_params={@table_params} />
            <.sort_header field={:base_ref} label="Base" table_params={@table_params} />
            <.sort_header field={:merged_at} label="Merged" table_params={@table_params} />
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
      {@label} {TableParams.sort_indicator(@table_params, @field)}
    </th>
    """
  end

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

  def handle_info({:set_lens, channel_name, rev}, socket) do
    {:noreply, TrackerWeb.LensHandlers.handle_lens_change(socket, channel_name, rev)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    tp = TableParams.from_params(params, @table_opts)
    base_ref_filter = Map.get(params, "base_ref", "")

    lens = socket.assigns.lens && %{socket.assigns.lens | disabled?: true}

    socket =
      socket
      |> assign(:page_title, "Changes")
      |> assign(:table_params, tp)
      |> assign(:base_ref_filter, base_ref_filter)
      |> assign(:lens, lens)
      |> load_changes()

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter", params, socket) do
    search = Map.get(params, "search", "")
    base_ref = Map.get(params, "base_ref", "")
    tp = %{socket.assigns.table_params | search: search, page: 1, offset: 0}

    socket =
      socket
      |> assign(:table_params, tp)
      |> assign(:base_ref_filter, base_ref)
      |> load_changes()
      |> push_event("update-url", %{
        path: TableParams.to_path(tp, "/changes", %{base_ref: base_ref})
      })

    {:noreply, socket}
  end

  @impl true
  def handle_event("sort", %{"field" => field}, socket) do
    tp = socket.assigns.table_params
    new_sort_by = TableParams.from_params(%{"sort_by" => field}, @table_opts).sort_by

    new_sort_dir =
      if tp.sort_by == new_sort_by, do: TableParams.toggle_dir(tp.sort_dir), else: :asc

    new_tp = %{tp | sort_by: new_sort_by, sort_dir: new_sort_dir, page: 1, offset: 0}

    {:noreply,
     push_patch(socket,
       to: TableParams.to_path(new_tp, "/changes", %{base_ref: socket.assigns.base_ref_filter})
     )}
  end

  @impl true
  def handle_event("next-page", _params, socket) do
    tp = socket.assigns.table_params

    {:noreply,
     push_patch(socket,
       to:
         TableParams.to_path(%{tp | page: tp.page + 1}, "/changes", %{
           base_ref: socket.assigns.base_ref_filter
         })
     )}
  end

  @impl true
  def handle_event("prev-page", _params, socket) do
    tp = socket.assigns.table_params

    {:noreply,
     push_patch(socket,
       to:
         TableParams.to_path(%{tp | page: max(tp.page - 1, 1)}, "/changes", %{
           base_ref: socket.assigns.base_ref_filter
         })
     )}
  end

  defp load_changes(socket) do
    tp = socket.assigns.table_params

    page =
      Tracker.Nixpkgs.Change.list!(tp.search, socket.assigns.base_ref_filter,
        actor: socket.assigns[:current_user],
        query: [sort: [{tp.sort_by, tp.sort_dir}]],
        page: [offset: tp.offset, count: true]
      )

    pagination = TableParams.apply_pagination(tp, page, :changes)

    socket
    |> stream(:changes, pagination.stream_results, reset: true)
    |> assign(:has_prev_page?, pagination.has_prev_page?)
    |> assign(:has_next_page?, pagination.has_next_page?)
    |> assign(:total_pages, pagination.total_pages)
    |> assign(:current_page, pagination.current_page)
  end

  defp load_base_refs do
    Tracker.Nixpkgs.Change.distinct_base_refs!()
    |> Enum.map(& &1.base_ref)
    |> Enum.reject(&is_nil/1)
  end
end

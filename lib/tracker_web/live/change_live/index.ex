defmodule TrackerWeb.ChangeLive.Index do
  use TrackerWeb, :live_view

  alias TrackerWeb.DataTable
  alias TrackerWeb.PageSearch
  alias TrackerWeb.TableParams

  @table_opts [
    allowed_sorts: ~w(number title author base_ref merged_at)a,
    default_sort: :number,
    default_sort_dir: :desc
  ]

  @impl true
  def render(assigns) do
    ~H"""
    <form
      method="get"
      action="/changes"
      phx-change="filter"
      phx-submit="filter"
      id="change-base-ref-filter"
      phx-hook="UpdateURL"
      style="display: flex; gap: 0.5rem; align-items: end; margin-bottom: 1rem;"
    >
      <input type="hidden" name="search" value={@table_params.search} />
      <select name="base_ref" aria-label="Filter by base branch" style="max-width: 16rem;">
        <option value="">All branches</option>
        <option :for={base <- @base_refs} value={base} selected={base == @base_ref_filter}>
          {base}
        </option>
      </select>
    </form>

    <DataTable.data_table
      id="changes"
      rows={@streams.changes}
      table_params={@table_params}
      base_path="/changes"
      total_pages={@total_pages}
      current_page={@current_page}
      has_prev_page?={@has_prev_page?}
      has_next_page?={@has_next_page?}
    >
      <:col :let={{_id, change}} field={:number} label="#" sortable>
        <.link navigate={~p"/changes/#{change.number}"}>{change.number}</.link>
      </:col>
      <:col :let={{_id, change}} field={:title} label="Title" sortable>
        <.link navigate={~p"/changes/#{change.number}"}>
          <span style="display: block; max-width: 50ch; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
            {change.title}
          </span>
        </.link>
      </:col>
      <:col :let={{_id, change}} field={:author} label="Author" sortable>
        {change.author}
      </:col>
      <:col :let={{_id, change}} field={:base_ref} label="Base" sortable>
        {change.base_ref}
      </:col>
      <:col :let={{_id, change}} field={:merged_at} label="Merged" sortable>
        {format_datetime(change.merged_at)}
      </:col>
    </DataTable.data_table>
    """
  end

  defp format_datetime(nil), do: "-"
  defp format_datetime(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Tracker.PubSub, "changes:updated")
    end

    base_refs = load_base_refs()
    {:ok, socket |> assign_new(:current_user, fn -> nil end) |> assign(:base_refs, base_refs)}
  end

  @impl true
  def handle_info(%Ash.Notifier.Notification{resource: Tracker.Nixpkgs.Change}, socket) do
    {:noreply, socket |> assign(:base_refs, load_base_refs()) |> load_changes()}
  end

  def handle_info({:set_lens, channel_name, rev}, socket) do
    socket = TrackerWeb.LensHandlers.handle_lens_change(socket, channel_name, rev)
    {:noreply, load_changes(socket)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    tp = TableParams.from_params(params, @table_opts)
    base_ref_filter = Map.get(params, "base_ref", "")

    socket =
      socket
      |> assign(:page_title, "Changes")
      |> assign(:table_params, tp)
      |> assign(:base_ref_filter, base_ref_filter)
      |> assign(:page_search, page_search(tp, base_ref_filter))
      |> load_changes()

    {:noreply, socket}
  end

  defp page_search(tp, base_ref_filter) do
    %PageSearch{
      action: "/changes",
      placeholder: "Filter changes…",
      value: tp.search,
      event: "filter",
      hidden: TableParams.to_hidden_inputs(tp, %{base_ref: base_ref_filter})
    }
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
    channel_name = TrackerWeb.Lens.channel_name(socket.assigns.lens)

    page =
      Tracker.Nixpkgs.Change.list!(tp.search, socket.assigns.base_ref_filter, channel_name,
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

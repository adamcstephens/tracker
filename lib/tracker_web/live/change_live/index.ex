defmodule TrackerWeb.ChangeLive.Index do
  use TrackerWeb, :live_view

  alias TrackerWeb.ChangeRow
  alias TrackerWeb.PageSearch
  alias TrackerWeb.Pagination
  alias TrackerWeb.TableParams

  @impl true
  def render(assigns) do
    ~H"""
    <form
      method="get"
      action="/changes"
      phx-change="filter"
      phx-submit="filter"
      id="change-base-ref-filter"
      class="change-filters"
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
      <label :if={@lens_channel_name}>
        <input type="checkbox" name="in_channel" value="1" checked={@in_channel_filter?} />
        Only in {@lens_channel_name}
      </label>
      <button type="submit">Apply</button>
    </form>

    <ChangeRow.change_row_list id="changes" phx-update="stream">
      <ChangeRow.change_row
        :for={{dom_id, change} <- @streams.changes}
        id={dom_id}
        change={change}
        landed_in={lens_landing(change, @lens_channel_name, @in_channel_filter?)}
      />
    </ChangeRow.change_row_list>

    <Pagination.controls
      total_pages={@total_pages}
      current_page={@current_page}
      has_prev_page?={@has_prev_page?}
      has_next_page?={@has_next_page?}
      prev_path={
        TableParams.page_path(
          @table_params,
          @current_page - 1,
          "/changes",
          filter_extras(@base_ref_filter, @in_channel_filter?)
        )
      }
      next_path={
        TableParams.page_path(
          @table_params,
          @current_page + 1,
          "/changes",
          filter_extras(@base_ref_filter, @in_channel_filter?)
        )
      }
      anchor="changes"
    />
    """
  end

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

  @impl true
  def handle_params(params, _url, socket) do
    tp = TableParams.from_params(params)
    base_ref_filter = Map.get(params, "base_ref", "")
    in_channel? = Map.get(params, "in_channel", "") == "1"

    socket =
      socket
      |> assign(:page_title, "Changes")
      |> assign(:table_params, tp)
      |> assign(:base_ref_filter, base_ref_filter)
      |> assign(:in_channel_filter?, in_channel?)
      |> assign(:page_search, page_search(tp, base_ref_filter, in_channel?))
      |> load_changes()

    {:noreply, socket}
  end

  defp page_search(tp, base_ref_filter, in_channel?) do
    %PageSearch{
      action: "/changes",
      value: tp.search,
      event: "filter",
      hidden: TableParams.to_hidden_inputs(tp, filter_extras(base_ref_filter, in_channel?))
    }
  end

  defp filter_extras(base_ref_filter, in_channel?) do
    %{base_ref: base_ref_filter, in_channel: if(in_channel?, do: "1", else: "")}
  end

  @impl true
  def handle_event("filter", params, socket) do
    search = Map.get(params, "search", "")
    base_ref = Map.get(params, "base_ref", "")
    in_channel? = Map.get(params, "in_channel", "") == "1"
    tp = %{socket.assigns.table_params | search: search, page: 1, offset: 0}

    socket =
      socket
      |> assign(:table_params, tp)
      |> assign(:base_ref_filter, base_ref)
      |> assign(:in_channel_filter?, in_channel?)
      |> assign(:page_search, page_search(tp, base_ref, in_channel?))
      |> load_changes()
      |> push_event("update-url", %{
        path: TableParams.to_path(tp, "/changes", filter_extras(base_ref, in_channel?))
      })

    {:noreply, socket}
  end

  defp load_changes(socket) do
    tp = socket.assigns.table_params
    channel_name = TrackerWeb.Lens.channel_name(socket.assigns.lens)
    filter_channel = if socket.assigns.in_channel_filter?, do: channel_name

    page =
      Tracker.Nixpkgs.Change.list!(tp.search, socket.assigns.base_ref_filter, filter_channel,
        actor: socket.assigns[:current_user],
        query: [sort: [number: :desc], load: branch_loads(channel_name)],
        page: [offset: tp.offset, count: true]
      )

    pagination = TableParams.apply_pagination(tp, page, :changes)

    socket
    |> assign(:lens_channel_name, channel_name)
    |> stream(:changes, pagination.stream_results, reset: true)
    |> assign(:has_prev_page?, pagination.has_prev_page?)
    |> assign(:has_next_page?, pagination.has_next_page?)
    |> assign(:total_pages, pagination.total_pages)
    |> assign(:current_page, pagination.current_page)
  end

  defp branch_loads(nil), do: []
  defp branch_loads(_channel_name), do: [:change_branches]

  defp lens_landing(_change, nil, _in_channel_filter?), do: nil
  defp lens_landing(_change, _channel_name, true), do: nil

  defp lens_landing(change, channel_name, false) do
    if Enum.any?(change.change_branches, &(&1.branch_name == channel_name)) do
      channel_name
    end
  end

  defp load_base_refs do
    Tracker.Nixpkgs.Change.distinct_base_refs!()
    |> Enum.map(& &1.base_ref)
    |> Enum.reject(&is_nil/1)
  end
end

defmodule TrackerWeb.ChangeLive.Index do
  use TrackerWeb, :live_view

  alias TrackerWeb.PageSearch
  alias TrackerWeb.Pagination
  alias TrackerWeb.RowList
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

    <RowList.row_list id="changes" phx-update="stream" stacked>
      <RowList.row
        :for={{dom_id, change} <- @streams.changes}
        id={dom_id}
        mode={:link}
        navigate={~p"/changes/#{change.number}"}
      >
        <:label>
          <span class="row-num">#{change.number}</span> {change.title}
        </:label>
        <:sublabel>
          <span class={"pill pill-#{change.state}"}>
            <span class="dot" aria-hidden="true"></span>
            {change.state}
          </span>
          <span>{change.base_ref}</span>
          <span
            :if={not @in_channel_filter? and landed_in_lens?(change, @lens_channel_name)}
            class="pill pill-landed"
          >
            in {@lens_channel_name}
          </span>
        </:sublabel>
        <:meta>{format_datetime(change.merged_at)}</:meta>
        <:actions>
          <a
            href={change.url}
            target="_blank"
            rel="noopener noreferrer"
            class="row-action"
            title="Open on GitHub"
            aria-label={"Open ##{change.number} on GitHub"}
            data-external-link
          >
            <.external_icon />
          </a>
        </:actions>
      </RowList.row>
    </RowList.row_list>

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
    />
    """
  end

  defp external_icon(assigns) do
    ~H"""
    <svg
      class="icon-external"
      aria-hidden="true"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.7"
      stroke-linecap="round"
      stroke-linejoin="round"
    >
      <path d="M14 4h6v6" />
      <path d="M20 4 10 14" />
      <path d="M19 13v6a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1h6" />
    </svg>
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

  @impl true
  def handle_event("next-page", _params, socket) do
    tp = socket.assigns.table_params

    {:noreply,
     push_patch(socket,
       to:
         TableParams.to_path(
           %{tp | page: tp.page + 1},
           "/changes",
           filter_extras(socket.assigns.base_ref_filter, socket.assigns.in_channel_filter?)
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
           "/changes",
           filter_extras(socket.assigns.base_ref_filter, socket.assigns.in_channel_filter?)
         )
     )}
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

  defp landed_in_lens?(_change, nil), do: false

  defp landed_in_lens?(change, channel_name) do
    Enum.any?(change.change_branches, &(&1.branch_name == channel_name))
  end

  defp load_base_refs do
    Tracker.Nixpkgs.Change.distinct_base_refs!()
    |> Enum.map(& &1.base_ref)
    |> Enum.reject(&is_nil/1)
  end
end

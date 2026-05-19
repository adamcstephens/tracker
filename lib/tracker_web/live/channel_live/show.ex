defmodule TrackerWeb.ChannelLive.Show do
  use TrackerWeb, :live_view

  alias TrackerWeb.DataTable
  alias TrackerWeb.PageSearch
  alias TrackerWeb.TableParams

  @table_opts [
    allowed_sorts: ~w(released_at revision result)a,
    default_sort: :released_at,
    default_sort_dir: :desc
  ]

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      {@channel}
      <:subtitle>Channel revisions</:subtitle>
      <:actions>
        <.link
          :if={@channel_resource.build_problem?}
          href={"https://hydra.nixos.org/jobset/#{@channel_resource.hydra_project}/#{@channel_resource.hydra_jobset}"}
          target="_blank"
          rel="noopener"
        >
          <.badge variant={:danger}>Build problem</.badge>
        </.link>
        <a href={"/feeds/channels/#{@channel}"} title="Atom feed">
          <img src="/images/feed.svg" alt="Atom feed" width="20" height="20" />
        </a>
      </:actions>
    </.header>

    <div :if={@has_revisions?}>
      <DataTable.data_table
        id="revisions"
        rows={@revisions}
        table_params={@table_params}
        base_path={"/channels/#{@channel}"}
        total_pages={@total_pages}
        current_page={@current_page}
        has_prev_page?={@has_prev_page?}
        has_next_page?={@has_next_page?}
      >
        <:col :let={rev} label="">
          <input
            type="checkbox"
            checked={rev.revision in @selected_revisions}
            phx-click="toggle-rev"
            phx-value-revision={rev.revision}
          />
        </:col>
        <:col :let={rev} field={:revision} label="Revision" sortable>
          <.revision_link revision={rev.revision} channel={@channel} />
        </:col>
        <:col :let={rev} field={:result} label="Result" sortable>
          {format_result(rev.result)}
        </:col>
        <:col :let={rev} field={:released_at} label="Released" sortable>
          {format_date(rev.released_at)}
        </:col>
      </DataTable.data_table>

      <a
        :if={length(@selected_revisions) == 2}
        href={
          ~p"/channels/#{@channel}/diff/#{Enum.at(@selected_revisions, 0)}/#{Enum.at(@selected_revisions, 1)}"
        }
        role="button"
        style="margin-top: 1rem; display: inline-block;"
      >
        Show diff
      </a>
    </div>

    <p :if={not @has_revisions?}>
      No revisions found.
    </p>
    """
  end

  defp revision_link(assigns) do
    ~H"""
    <.link
      navigate={~p"/channels/#{@channel}/revisions/#{@revision}"}
      title={@revision}
      class="revision-link"
    >
      {String.slice(@revision, 0, 7)}
    </.link>
    """
  end

  defp format_date(nil), do: "-"
  defp format_date(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  defp format_result(nil), do: "-"
  defp format_result(:success), do: "Success"
  defp format_result(:partial_success), do: "Partial"
  defp format_result(:error), do: "Error"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign_new(:current_user, fn -> nil end)
     |> assign(:selected_revisions, [])
     |> assign(:subscribed_channel, nil)}
  end

  @impl true
  def handle_params(%{"channel" => channel_name} = params, _url, socket) do
    channel = Tracker.Nixpkgs.Channel.by_name!(channel_name, load: [:build_problem?])

    if connected?(socket) && socket.assigns.subscribed_channel != channel_name do
      if socket.assigns.subscribed_channel do
        Phoenix.PubSub.unsubscribe(
          Tracker.PubSub,
          "channel_revisions:#{socket.assigns.subscribed_channel}"
        )
      end

      Phoenix.PubSub.subscribe(Tracker.PubSub, "channel_revisions:#{channel_name}")
    end

    tp = TableParams.from_params(params, @table_opts)

    lens = socket.assigns.lens && %{socket.assigns.lens | disabled?: true}

    {:noreply,
     socket
     |> assign(:page_title, channel_name)
     |> assign(:channel, channel_name)
     |> assign(:channel_resource, channel)
     |> assign(:table_params, tp)
     |> assign(:subscribed_channel, channel_name)
     |> assign(:lens, lens)
     |> assign(:page_search, %PageSearch{
       mode: :inert,
       value: Map.get(params, "search", "")
     })
     |> assign_revisions(channel.id)}
  end

  @impl true
  def handle_info({event, _payload}, socket)
      when event in [:channel_revision_created, :channel_revision_completed] do
    {:noreply, assign_revisions(socket, socket.assigns.channel_resource.id)}
  end

  def handle_info({:set_lens, channel_name, rev}, socket) do
    {:noreply, TrackerWeb.LensHandlers.handle_lens_change(socket, channel_name, rev)}
  end

  defp assign_revisions(socket, channel_id) do
    tp = socket.assigns.table_params

    page =
      Tracker.Nixpkgs.ChannelRevision.list_by_channel!(channel_id,
        query: [sort: [{tp.sort_by, tp.sort_dir}]],
        page: [offset: tp.offset, count: true]
      )

    pagination = TableParams.apply_pagination(tp, page, :revisions)

    socket
    |> assign(:revisions, pagination.stream_results)
    |> assign(:has_revisions?, pagination.stream_results != [])
    |> assign(:has_prev_page?, pagination.has_prev_page?)
    |> assign(:has_next_page?, pagination.has_next_page?)
    |> assign(:total_pages, pagination.total_pages)
    |> assign(:current_page, pagination.current_page)
  end

  @impl true
  def handle_event("sort", %{"field" => field}, socket) do
    tp = socket.assigns.table_params
    new_sort_by = TableParams.from_params(%{"sort_by" => field}, @table_opts).sort_by

    new_sort_dir =
      if tp.sort_by == new_sort_by, do: TableParams.toggle_dir(tp.sort_dir), else: :asc

    new_tp = %{tp | sort_by: new_sort_by, sort_dir: new_sort_dir, page: 1, offset: 0}

    {:noreply,
     push_patch(socket, to: TableParams.to_path(new_tp, "/channels/#{socket.assigns.channel}"))}
  end

  @impl true
  def handle_event("next-page", _params, socket) do
    tp = socket.assigns.table_params

    {:noreply,
     push_patch(socket,
       to: TableParams.to_path(%{tp | page: tp.page + 1}, "/channels/#{socket.assigns.channel}")
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
           "/channels/#{socket.assigns.channel}"
         )
     )}
  end

  @impl true
  def handle_event("toggle-rev", %{"revision" => revision}, socket) do
    selected = socket.assigns.selected_revisions

    selected =
      if revision in selected do
        List.delete(selected, revision)
      else
        case selected do
          [_a, _b] -> [List.last(selected), revision]
          _ -> selected ++ [revision]
        end
      end

    {:noreply, assign(socket, :selected_revisions, selected)}
  end
end

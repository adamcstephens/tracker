defmodule TrackerWeb.ChannelLive.Show do
  use TrackerWeb, :live_view

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
        <a href={"/feeds/channels/#{@channel}"} title="Atom feed">
          <img src="/images/feed.svg" alt="Atom feed" width="20" height="20" />
        </a>
      </:actions>
    </.header>

    <figure :if={@has_revisions?}>
      <table role="grid">
        <thead>
          <tr>
            <th></th>
            <.sort_header field={:revision} label="Revision" table_params={@table_params} />
            <.sort_header field={:result} label="Result" table_params={@table_params} />
            <.sort_header field={:released_at} label="Released" table_params={@table_params} />
          </tr>
        </thead>
        <tbody id="revisions">
          <tr :for={rev <- @revisions}>
            <td>
              <input
                type="checkbox"
                checked={rev.revision in @selected_revisions}
                phx-click="toggle-rev"
                phx-value-revision={rev.revision}
              />
            </td>
            <td>
              <.revision_link revision={rev.revision} channel={@channel} />
            </td>
            <td>{format_result(rev.result)}</td>
            <td>{format_date(rev.released_at)}</td>
          </tr>
        </tbody>
      </table>
    </figure>

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

    <p :if={not @has_revisions?}>
      No revisions found.
    </p>

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

  defp sort_header(assigns) do
    ~H"""
    <th phx-click="sort" phx-value-field={@field} style="cursor: pointer">
      {@label} {TableParams.sort_indicator(@table_params, @field)}
    </th>
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
    channel = Tracker.Nixpkgs.Channel.by_name!(channel_name)

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

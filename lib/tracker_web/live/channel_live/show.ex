defmodule TrackerWeb.ChannelLive.Show do
  use TrackerWeb, :live_view

  @valid_sort_fields ~w(released_at revision result)a
  @default_sort_by :released_at
  @default_sort_dir :desc

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      {@channel}
      <:subtitle>Channel revisions</:subtitle>
    </.header>

    <figure :if={@has_revisions?}>
      <table role="grid">
        <thead>
          <tr>
            <.sort_header
              field={:revision}
              label="Revision"
              sort_by={@sort_by}
              sort_dir={@sort_dir}
            />
            <.sort_header
              field={:result}
              label="Result"
              sort_by={@sort_by}
              sort_dir={@sort_dir}
            />
            <.sort_header
              field={:released_at}
              label="Released"
              sort_by={@sort_by}
              sort_dir={@sort_dir}
            />
          </tr>
        </thead>
        <tbody id="revisions">
          <tr :for={rev <- @revisions}>
            <td>
              <.revision_link revision={rev.revision} />
            </td>
            <td>{format_result(rev.result)}</td>
            <td>{format_date(rev.released_at)}</td>
          </tr>
        </tbody>
      </table>
    </figure>

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

    <.back navigate={~p"/channels"}>Back to channels</.back>
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

  defp revision_link(assigns) do
    ~H"""
    <a
      href={"https://github.com/NixOS/nixpkgs/commit/#{@revision}"}
      target="_blank"
      rel="noopener noreferrer"
      title={@revision}
      class="revision-link"
    >
      {String.slice(@revision, 0, 7)}
    </a>
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
    {:ok, assign_new(socket, :current_user, fn -> nil end)}
  end

  @impl true
  def handle_params(%{"channel" => channel} = params, _url, socket) do
    sort_by = parse_sort_by(params["sort_by"])
    sort_dir = parse_sort_dir(params["sort_dir"])
    page = params |> Map.get("page", "1") |> String.to_integer() |> max(1)
    offset = (page - 1) * 15

    revisions = load_revisions(channel, sort_by, sort_dir, offset)

    total_pages = ceil(revisions.count / 15)
    current_page = div(offset, 15) + 1

    {:noreply,
     socket
     |> assign(:page_title, channel)
     |> assign(:channel, channel)
     |> assign(:revisions, revisions.results)
     |> assign(:has_revisions?, revisions.results != [])
     |> assign(:sort_by, sort_by)
     |> assign(:sort_dir, sort_dir)
     |> assign(:has_prev_page?, offset > 0)
     |> assign(:has_next_page?, revisions.more?)
     |> assign(:total_pages, total_pages)
     |> assign(:current_page, current_page)}
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
       to: channel_path(socket.assigns.channel, new_sort_by, new_sort_dir, 1)
     )}
  end

  @impl true
  def handle_event("next-page", _params, socket) do
    {:noreply,
     push_patch(socket,
       to:
         channel_path(
           socket.assigns.channel,
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
         channel_path(
           socket.assigns.channel,
           socket.assigns.sort_by,
           socket.assigns.sort_dir,
           max(socket.assigns.current_page - 1, 1)
         )
     )}
  end

  defp load_revisions(channel, sort_by, sort_dir, offset) do
    Tracker.Nixpkgs.ChannelRevision.list_by_channel!(channel,
      query: [sort: [{sort_by, sort_dir}]],
      page: [offset: offset, count: true]
    )
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

  defp channel_path(channel, sort_by, sort_dir, page) do
    params =
      %{}
      |> then(fn p ->
        if sort_by != @default_sort_by, do: Map.put(p, :sort_by, sort_by), else: p
      end)
      |> then(fn p ->
        if sort_dir != @default_sort_dir, do: Map.put(p, :sort_dir, sort_dir), else: p
      end)
      |> then(fn p -> if page > 1, do: Map.put(p, :page, page), else: p end)

    case URI.encode_query(params) do
      "" -> "/channels/#{channel}"
      qs -> "/channels/#{channel}?#{qs}"
    end
  end
end

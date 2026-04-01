defmodule TrackerWeb.ChannelLive.Index do
  use TrackerWeb, :live_view

  @valid_sort_fields ~w(name count latest_release)a
  @default_sort_by :latest_release
  @default_sort_dir :desc

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Channels
    </.header>

    <figure>
      <table role="grid">
        <thead>
          <tr>
            <.sort_header field={:name} label="Channel" sort_by={@sort_by} sort_dir={@sort_dir} />
            <.sort_header
              field={:count}
              label="Revisions"
              sort_by={@sort_by}
              sort_dir={@sort_dir}
            />
            <.sort_header
              field={:latest_release}
              label="Latest Release"
              sort_by={@sort_by}
              sort_dir={@sort_dir}
            />
          </tr>
        </thead>
        <tbody id="channels" phx-update="stream">
          <tr
            :for={{dom_id, channel} <- @streams.channels}
            id={dom_id}
          >
            <td><.link navigate={~p"/channels/#{channel.name}"}>{channel.name}</.link></td>
            <td>{channel.count}</td>
            <td>{format_date(channel.latest_release)}</td>
          </tr>
        </tbody>
      </table>
    </figure>
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

  defp format_date(nil), do: "-"
  defp format_date(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_new(socket, :current_user, fn -> nil end)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    sort_by = parse_sort_by(params["sort_by"])
    sort_dir = parse_sort_dir(params["sort_dir"])

    channels = load_channels(sort_by, sort_dir)

    {:noreply,
     socket
     |> assign(:page_title, "Channels")
     |> assign(:sort_by, sort_by)
     |> assign(:sort_dir, sort_dir)
     |> stream(:channels, channels, reset: true)}
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

    {:noreply, push_patch(socket, to: channels_path(new_sort_by, new_sort_dir))}
  end

  defp load_channels(sort_by, sort_dir) do
    Tracker.Nixpkgs.ChannelRevision.read!()
    |> Enum.group_by(& &1.channel)
    |> Enum.map(fn {name, revisions} ->
      latest = revisions |> Enum.max_by(& &1.released_at, DateTime, fn -> nil end)

      %{
        id: name,
        name: name,
        count: length(revisions),
        latest_release: latest && latest.released_at
      }
    end)
    |> sort_channels(sort_by, sort_dir)
  end

  defp sort_channels(channels, :name, dir), do: sort_by_field(channels, & &1.name, dir)
  defp sort_channels(channels, :count, dir), do: sort_by_field(channels, & &1.count, dir)

  defp sort_channels(channels, :latest_release, dir),
    do: sort_by_field(channels, & &1.latest_release, dir)

  defp sort_by_field(channels, fun, :asc), do: Enum.sort_by(channels, fun, &<=/2)
  defp sort_by_field(channels, fun, :desc), do: Enum.sort_by(channels, fun, &>=/2)

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

  defp channels_path(sort_by, sort_dir) do
    params =
      %{}
      |> then(fn p ->
        if sort_by != @default_sort_by, do: Map.put(p, :sort_by, sort_by), else: p
      end)
      |> then(fn p ->
        if sort_dir != @default_sort_dir, do: Map.put(p, :sort_dir, sort_dir), else: p
      end)

    case URI.encode_query(params) do
      "" -> "/channels"
      qs -> "/channels?#{qs}"
    end
  end
end

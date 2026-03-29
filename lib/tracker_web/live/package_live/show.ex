defmodule TrackerWeb.PackageLive.Show do
  use TrackerWeb, :live_view

  require Ash.Query

  @valid_sort_fields ~w(version channel revision_hash released_at)a
  @default_sort_by :released_at
  @default_sort_dir :desc

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      {@package.attribute}
    </.header>

    <p :if={@package.description}>{@package.description}</p>

    <.list>
      <:item title="Attribute">{@package.attribute}</:item>
      <:item :if={@package.homepage} title="Homepage">
        <a href={@package.homepage} target="_blank" rel="noopener noreferrer">
          {@package.homepage}
        </a>
      </:item>
      <:item :if={@package.position} title="Position">
        <.nixpkgs_position position={@package.position} />
      </:item>
    </.list>

    <div class="revisions-header">
      <h2>Revisions</h2>

      <form phx-change="filter" phx-submit="filter" class="revision-filters">
        <select name="channel" aria-label="Filter by channel">
          <option value="">All channels</option>
          <option :for={ch <- @channels} value={ch} selected={ch == @channel_filter}>
            {ch}
          </option>
        </select>
        <input
          type="search"
          name="version"
          value={@version_filter}
          placeholder="Filter by version..."
          phx-debounce="300"
        />
      </form>
    </div>

    <figure :if={@revisions != []}>
      <table role="grid">
        <thead>
          <tr>
            <.sort_header field={:version} label="Version" sort_by={@sort_by} sort_dir={@sort_dir} />
            <.sort_header field={:channel} label="Channel" sort_by={@sort_by} sort_dir={@sort_dir} />
            <.sort_header
              field={:revision_hash}
              label="Revision"
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
            <td>{rev.version}</td>
            <td>{rev.channel_revision.channel}</td>
            <td>
              <.revision_link revision={rev.channel_revision.revision} />
            </td>
            <td>{format_released_at(rev.channel_revision.released_at)}</td>
          </tr>
        </tbody>
      </table>
    </figure>

    <p :if={@revisions == []}>
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

    <.back navigate={~p"/packages"}>Back to packages</.back>
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

  defp nixpkgs_position(assigns) do
    [path, line] =
      case String.split(assigns.position, ":") do
        [path, line] -> [path, line]
        [path] -> [path, nil]
      end

    assigns = assign(assigns, path: path, line: line)

    ~H"""
    <a
      href={"https://github.com/NixOS/nixpkgs/blob/master/#{@path}" <> if(@line, do: "#L#{@line}", else: "")}
      target="_blank"
      rel="noopener noreferrer"
    >
      {@position}
    </a>
    """
  end

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

  defp format_released_at(nil), do: "-"
  defp format_released_at(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"name" => name} = params, _url, socket) do
    package = Ash.get!(Tracker.Nixpkgs.Package, %{attribute: name})

    sort_by = parse_sort_by(params["sort_by"])
    sort_dir = parse_sort_dir(params["sort_dir"])
    channel_filter = params["channel"] || ""
    version_filter = params["version"] || ""
    page = params |> Map.get("page", "1") |> String.to_integer() |> max(1)
    offset = (page - 1) * 15

    result = load_revisions(package.id, sort_by, sort_dir, channel_filter, version_filter, offset)
    channels = load_channels()

    total_pages = ceil(result.count / 15)
    current_page = div(offset, 15) + 1

    {:noreply,
     socket
     |> assign(:page_title, package.attribute)
     |> assign(:package, package)
     |> assign(:revisions, result.results)
     |> assign(:sort_by, sort_by)
     |> assign(:sort_dir, sort_dir)
     |> assign(:channel_filter, channel_filter)
     |> assign(:version_filter, version_filter)
     |> assign(:channels, channels)
     |> assign(:has_prev_page?, offset > 0)
     |> assign(:has_next_page?, result.more?)
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
       to:
         revisions_path(
           socket.assigns.package.attribute,
           new_sort_by,
           new_sort_dir,
           socket.assigns.channel_filter,
           socket.assigns.version_filter,
           1
         )
     )}
  end

  @impl true
  def handle_event("filter", params, socket) do
    channel = Map.get(params, "channel", "")
    version = Map.get(params, "version", "")

    {:noreply,
     push_patch(socket,
       to:
         revisions_path(
           socket.assigns.package.attribute,
           socket.assigns.sort_by,
           socket.assigns.sort_dir,
           channel,
           version,
           1
         )
     )}
  end

  @impl true
  def handle_event("next-page", _params, socket) do
    {:noreply,
     push_patch(socket,
       to:
         revisions_path(
           socket.assigns.package.attribute,
           socket.assigns.sort_by,
           socket.assigns.sort_dir,
           socket.assigns.channel_filter,
           socket.assigns.version_filter,
           socket.assigns.current_page + 1
         )
     )}
  end

  @impl true
  def handle_event("prev-page", _params, socket) do
    {:noreply,
     push_patch(socket,
       to:
         revisions_path(
           socket.assigns.package.attribute,
           socket.assigns.sort_by,
           socket.assigns.sort_dir,
           socket.assigns.channel_filter,
           socket.assigns.version_filter,
           max(socket.assigns.current_page - 1, 1)
         )
     )}
  end

  defp load_revisions(package_id, sort_by, sort_dir, channel_filter, version_filter, offset) do
    Tracker.Nixpkgs.PackageRevision
    |> Ash.Query.for_read(:list_by_package, %{package_id: package_id})
    |> maybe_filter_channel(channel_filter)
    |> maybe_filter_version(version_filter)
    |> Ash.Query.sort([{sort_by, sort_dir}])
    |> Ash.read!(page: [offset: offset, count: true])
  end

  defp maybe_filter_channel(query, ""), do: query

  defp maybe_filter_channel(query, channel) do
    Ash.Query.filter(query, channel_revision.channel == ^channel)
  end

  defp maybe_filter_version(query, ""), do: query

  defp maybe_filter_version(query, version) do
    Ash.Query.filter(query, contains(version, ^version))
  end

  defp load_channels do
    Tracker.Nixpkgs.ChannelRevision
    |> Ash.Query.distinct(:channel)
    |> Ash.Query.sort(:channel)
    |> Ash.read!()
    |> Enum.map(& &1.channel)
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

  defp revisions_path(package_name, sort_by, sort_dir, channel, version, page) do
    params =
      %{}
      |> then(fn p ->
        if sort_by != @default_sort_by, do: Map.put(p, :sort_by, sort_by), else: p
      end)
      |> then(fn p ->
        if sort_dir != @default_sort_dir, do: Map.put(p, :sort_dir, sort_dir), else: p
      end)
      |> then(fn p -> if channel != "", do: Map.put(p, :channel, channel), else: p end)
      |> then(fn p -> if version != "", do: Map.put(p, :version, version), else: p end)
      |> then(fn p -> if page > 1, do: Map.put(p, :page, page), else: p end)

    case URI.encode_query(params) do
      "" -> "/packages/#{package_name}"
      qs -> "/packages/#{package_name}?#{qs}"
    end
  end
end

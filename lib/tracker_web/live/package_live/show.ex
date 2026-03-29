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
      <:subtitle>Package details</:subtitle>
    </.header>

    <.list>
      <:item title="Id">{@package.id}</:item>

      <:item title="Attribute">{@package.attribute}</:item>
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

    revisions = load_revisions(package.id, sort_by, sort_dir, channel_filter, version_filter)
    channels = load_channels()

    {:noreply,
     socket
     |> assign(:page_title, package.attribute)
     |> assign(:package, package)
     |> assign(:revisions, revisions)
     |> assign(:sort_by, sort_by)
     |> assign(:sort_dir, sort_dir)
     |> assign(:channel_filter, channel_filter)
     |> assign(:version_filter, version_filter)
     |> assign(:channels, channels)}
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
           socket.assigns.version_filter
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
           version
         )
     )}
  end

  defp load_revisions(package_id, sort_by, sort_dir, channel_filter, version_filter) do
    Tracker.Nixpkgs.PackageRevision
    |> Ash.Query.filter(package_id == ^package_id)
    |> Ash.Query.load(:channel_revision)
    |> maybe_filter_channel(channel_filter)
    |> maybe_filter_version(version_filter)
    |> Ash.Query.sort([{sort_by, sort_dir}])
    |> Ash.read!()
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
    |> Ash.Query.sort(:channel)
    |> Ash.read!()
    |> Enum.map(& &1.channel)
    |> Enum.uniq()
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

  defp revisions_path(package_name, sort_by, sort_dir, channel, version) do
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

    case URI.encode_query(params) do
      "" -> "/packages/#{package_name}"
      qs -> "/packages/#{package_name}?#{qs}"
    end
  end
end

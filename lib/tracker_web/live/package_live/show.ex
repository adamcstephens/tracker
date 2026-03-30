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
      <:item :if={@package.licenses} title="License">
        {Enum.join(@package.licenses, ", ")}
      </:item>
    </.list>

    <dl :if={@package.teams != []}>
      <dt><strong>Teams</strong></dt>
      <dd :for={t <- @package.teams}>
        <.link navigate={~p"/teams/#{t.short_name}"}>{t.short_name}</.link>
        <span :if={t.scope}> —     {t.scope}</span>
      </dd>
    </dl>

    <dl :if={@package.maintainers != []}>
      <dt><strong>Maintainers</strong></dt>
      <dd :for={m <- @package.maintainers}>
        <.maintainer_link maintainer={m} />
      </dd>
    </dl>

    <dl :if={@family_siblings != []}>
      <dt><strong>Also available in</strong></dt>
      <dd :for={sibling <- @family_siblings}>
        <.link navigate={~p"/packages/#{sibling.attribute}"}>
          {sibling.package_set || sibling.attribute}
        </.link>
        <span :if={sibling.set_version}> ({sibling.set_version})</span>
      </dd>
    </dl>

    <section :if={@package_events != []}>
      <h2>Lifecycle Events</h2>
      <figure>
        <table role="grid">
          <thead>
            <tr>
              <th>Event</th>
              <th>Channel</th>
              <th>Revision</th>
              <th>Date</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={event <- @package_events}>
              <td>
                <mark :if={event.type == :added}>added</mark>
                <del :if={event.type == :removed}>removed</del>
              </td>
              <td>{event.channel_revision.channel}</td>
              <td>
                <.revision_link revision={event.channel_revision.revision} />
              </td>
              <td>{format_released_at(event.channel_revision.released_at)}</td>
            </tr>
          </tbody>
        </table>
      </figure>
    </section>

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
          type="text"
          name="version"
          value={@version_filter}
          placeholder="Filter by version..."
          phx-debounce="300"
        />
        <label>
          <input type="hidden" name="all_revisions" value="false" />
          <input
            type="checkbox"
            name="all_revisions"
            value="true"
            checked={@all_revisions?}
          /> All revisions
        </label>
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

  defp maintainer_link(assigns) do
    ~H"""
    <.link :if={@maintainer.github} navigate={~p"/maintainers/#{@maintainer.github}"}>
      {@maintainer.name || @maintainer.github}
    </.link>
    <span :if={!@maintainer.github}>{@maintainer.name || "Unknown"}</span>
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
    package =
      Ash.get!(Tracker.Nixpkgs.Package, %{attribute: name})
      |> Ash.load!([:maintainers, :teams])

    family_siblings = load_family_siblings(package)
    package_events = load_package_events(package.id)

    sort_by = parse_sort_by(params["sort_by"])
    sort_dir = parse_sort_dir(params["sort_dir"])
    channel_filter = params["channel"] || ""
    version_filter = params["version"] || ""
    all_revisions? = params["all_revisions"] == "true"
    page = params |> Map.get("page", "1") |> String.to_integer() |> max(1)
    offset = (page - 1) * 15

    channels = load_channels()

    {revisions, total_count, has_more?} =
      if all_revisions? do
        result =
          load_revisions(package.id, sort_by, sort_dir, channel_filter, version_filter, offset)

        {result.results, result.count, result.more?}
      else
        all_changes =
          load_version_changes(package.id, sort_by, sort_dir, channel_filter, version_filter)

        page_results = all_changes |> Enum.drop(offset) |> Enum.take(15)
        {page_results, length(all_changes), length(all_changes) > offset + 15}
      end

    total_pages = ceil(total_count / 15)
    current_page = div(offset, 15) + 1

    {:noreply,
     socket
     |> assign(:page_title, package.attribute)
     |> assign(:package, package)
     |> assign(:family_siblings, family_siblings)
     |> assign(:package_events, package_events)
     |> assign(:revisions, revisions)
     |> assign(:sort_by, sort_by)
     |> assign(:sort_dir, sort_dir)
     |> assign(:channel_filter, channel_filter)
     |> assign(:version_filter, version_filter)
     |> assign(:all_revisions?, all_revisions?)
     |> assign(:channels, channels)
     |> assign(:has_prev_page?, offset > 0)
     |> assign(:has_next_page?, has_more?)
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
           socket.assigns.all_revisions?,
           1
         )
     )}
  end

  @impl true
  def handle_event("filter", params, socket) do
    channel = Map.get(params, "channel", "")
    version = Map.get(params, "version", "")
    all_revisions? = Map.get(params, "all_revisions", "false") == "true"

    {:noreply,
     push_patch(socket,
       to:
         revisions_path(
           socket.assigns.package.attribute,
           socket.assigns.sort_by,
           socket.assigns.sort_dir,
           channel,
           version,
           all_revisions?,
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
           socket.assigns.all_revisions?,
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
           socket.assigns.all_revisions?,
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

  defp load_family_siblings(%{package_family_id: nil}), do: []

  defp load_family_siblings(package) do
    Tracker.Nixpkgs.Package
    |> Ash.Query.filter(package_family_id == ^package.package_family_id and id != ^package.id)
    |> Ash.Query.sort(:package_set)
    |> Ash.read!()
  end

  defp load_package_events(package_id) do
    Tracker.Nixpkgs.PackageEvent.list_by_package!(package_id)
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

  defp load_version_changes(package_id, sort_by, sort_dir, channel_filter, version_filter) do
    # Load all revisions for this package ordered by release date
    # to determine which ones represent actual version changes per channel
    all_revisions =
      Tracker.Nixpkgs.PackageRevision
      |> Ash.Query.for_read(:version_changes_by_package, %{package_id: package_id})
      |> Ash.read!()

    # Group by channel and find IDs where version changed
    change_ids =
      all_revisions
      |> Enum.group_by(& &1.channel_revision.channel)
      |> Enum.flat_map(fn {_channel, channel_revs} ->
        channel_revs
        |> Enum.reduce({nil, []}, fn rev, {prev_version, acc} ->
          if rev.version != prev_version do
            {rev.version, [rev.id | acc]}
          else
            {prev_version, acc}
          end
        end)
        |> elem(1)
      end)
      |> MapSet.new()

    all_revisions
    |> Enum.filter(&MapSet.member?(change_ids, &1.id))
    |> maybe_filter_channel_list(channel_filter)
    |> maybe_filter_version_list(version_filter)
    |> Enum.sort_by(&sort_key(&1, sort_by), sort_dir)
  end

  defp maybe_filter_channel_list(revisions, ""), do: revisions

  defp maybe_filter_channel_list(revisions, channel) do
    Enum.filter(revisions, &(&1.channel_revision.channel == channel))
  end

  defp maybe_filter_version_list(revisions, ""), do: revisions

  defp maybe_filter_version_list(revisions, version) do
    Enum.filter(revisions, &String.contains?(&1.version, version))
  end

  defp sort_key(rev, :version), do: rev.version
  defp sort_key(rev, :channel), do: rev.channel_revision.channel
  defp sort_key(rev, :revision_hash), do: rev.channel_revision.revision
  defp sort_key(rev, :released_at), do: rev.channel_revision.released_at

  defp revisions_path(package_name, sort_by, sort_dir, channel, version, all_revisions?, page) do
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
      |> then(fn p -> if all_revisions?, do: Map.put(p, :all_revisions, true), else: p end)
      |> then(fn p -> if page > 1, do: Map.put(p, :page, page), else: p end)

    case URI.encode_query(params) do
      "" -> "/packages/#{package_name}"
      qs -> "/packages/#{package_name}?#{qs}"
    end
  end
end

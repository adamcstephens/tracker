defmodule TrackerWeb.PackageLive.Show do
  use TrackerWeb, :live_view

  @valid_sort_fields ~w(version channel_name revision_hash released_at)a
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
        <span :for={url <- @package.homepage}>
          <a href={url} target="_blank" rel="noopener noreferrer">
            {url}
          </a>
        </span>
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
        <span :if={t.scope}>{t.scope}</span>
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

    <dl :if={@variant_siblings != []}>
      <dt><strong>Variants</strong></dt>
      <dd :for={variant <- @variant_siblings}>
        <.link navigate={~p"/packages/#{variant.attribute}"}>
          {variant.attribute}
        </.link>
      </dd>
    </dl>

    <section :if={@package.options != []}>
      <h2>NixOS Options</h2>
      <ul>
        <li :for={opt <- @package.options}>
          <.link :if={opt.module} navigate={"/modules/#{opt.module.display_name}#opt-#{opt.name}"}>
            {opt.name}
          </.link>
          <span :if={!opt.module}>{opt.name}</span>
          <% rev = Map.get(@option_revisions, opt.id) %>
          <small :if={rev}>
            <span :if={rev.type}> ({rev.type})</span>
            <span :if={rev.description}>{rev.description}</span>
          </small>
        </li>
      </ul>
    </section>

    <section :if={@recent_changes != []}>
      <h2>Recent Changes</h2>
      <figure>
        <table role="grid">
          <thead>
            <tr>
              <th>#</th>
              <th>Title</th>
              <th>Author</th>
              <th>Merged</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={change <- @recent_changes}>
              <td>
                <.link navigate={~p"/changes/#{change.number}"}>{change.number}</.link>
              </td>
              <td>
                <span style="display: block; max-width: 40ch; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
                  {change.title}
                </span>
              </td>
              <td>{change.author}</td>
              <td>{format_released_at(change.merged_at)}</td>
            </tr>
          </tbody>
        </table>
      </figure>
    </section>

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
              <td>{event.channel_revision.channel.name}</td>
              <td>
                <.revision_link
                  revision={event.channel_revision.revision}
                  channel={event.channel_revision.channel.name}
                />
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
          <option :for={ch <- @channels} value={ch.name} selected={ch.name == @channel_filter}>
            {ch.name}
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
        <button type="submit">Filter</button>
        <a
          href={"/feeds/packages/#{@package.attribute}"}
          title="Atom feed"
          style="display: flex; align-items: center;"
        >
          <img src="/images/feed.svg" alt="Atom feed" width="20" height="20" />
        </a>
      </form>
    </div>

    <figure :if={@revisions != []}>
      <table role="grid">
        <thead>
          <tr>
            <.sort_header field={:version} label="Version" sort_by={@sort_by} sort_dir={@sort_dir} />
            <.sort_header
              field={:channel_name}
              label="Channel"
              sort_by={@sort_by}
              sort_dir={@sort_dir}
            />
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
            <td>
              <.github_version_link
                version={rev.version}
                position={@package.position}
                revision={rev_revision(rev)}
              />
            </td>
            <td>{rev_channel(rev)}</td>
            <td>
              <.revision_link
                revision={rev_revision(rev)}
                channel={rev_channel(rev)}
              />
            </td>
            <td>{format_released_at(rev_released_at(rev))}</td>
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

  defp github_version_link(%{position: nil} = assigns) do
    ~H"{@version}"
  end

  defp github_version_link(assigns) do
    path = assigns.position |> String.split(":") |> hd()
    assigns = assign(assigns, :path, path)

    ~H"""
    <a
      href={"https://github.com/NixOS/nixpkgs/blob/#{@revision}/#{@path}"}
      target="_blank"
      rel="noopener noreferrer"
    >
      {@version}
    </a>
    """
  end

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
      {@maintainer.github}
    </.link>
    <span :if={!@maintainer.github}>Unknown</span>
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

  alias Tracker.Nixpkgs.PackageRevision.VersionChange

  defp rev_channel(%VersionChange{channel_name: channel_name}), do: channel_name
  defp rev_channel(%{channel_revision: %{channel: %{name: name}}}), do: name

  defp rev_revision(%VersionChange{revision: revision}), do: revision
  defp rev_revision(%{channel_revision: %{revision: revision}}), do: revision

  defp rev_released_at(%VersionChange{released_at: released_at}), do: released_at
  defp rev_released_at(%{channel_revision: %{released_at: released_at}}), do: released_at

  defp format_released_at(nil), do: "-"
  defp format_released_at(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :subscribed_channels, [])}
  end

  @impl true
  def handle_params(%{"name" => name} = params, _url, socket) do
    package =
      Tracker.Nixpkgs.Package.get_by_attribute!(name,
        load: [:maintainers, :teams, options: [:module]]
      )

    recent_changes = load_recent_changes(package.id)
    family_siblings = load_family_siblings(package)
    variant_siblings = load_variant_siblings(package)
    option_ids = Enum.map(package.options, & &1.id)

    option_revisions =
      option_ids
      |> Tracker.Nixpkgs.OptionRevision.latest_by_option_ids!()
      |> Map.new(&{&1.option_id, &1})

    sort_by = parse_sort_by(params["sort_by"])
    sort_dir = parse_sort_dir(params["sort_dir"])
    channel_filter = params["channel"] || ""
    version_filter = params["version"] || ""
    all_revisions? = params["all_revisions"] == "true"
    page = params |> Map.get("page", "1") |> String.to_integer() |> max(1)

    channels = load_channels()
    channel_names = Enum.map(channels, & &1.name)

    if connected?(socket) do
      old_channels = socket.assigns.subscribed_channels
      new_channels = channel_names

      for ch <- old_channels -- new_channels do
        Phoenix.PubSub.unsubscribe(Tracker.PubSub, "channel_revisions:#{ch}")
      end

      for ch <- new_channels -- old_channels do
        Phoenix.PubSub.subscribe(Tracker.PubSub, "channel_revisions:#{ch}")
      end

      Phoenix.PubSub.subscribe(Tracker.PubSub, "changes")
    end

    {:noreply,
     socket
     |> assign(:page_title, package.attribute)
     |> assign(:package, package)
     |> assign(:recent_changes, recent_changes)
     |> assign(:family_siblings, family_siblings)
     |> assign(:variant_siblings, variant_siblings)
     |> assign(:option_revisions, option_revisions)
     |> assign(:sort_by, sort_by)
     |> assign(:sort_dir, sort_dir)
     |> assign(:channel_filter, channel_filter)
     |> assign(:version_filter, version_filter)
     |> assign(:all_revisions?, all_revisions?)
     |> assign(:channels, channels)
     |> assign(:subscribed_channels, channel_names)
     |> assign_package_data(
       package.id,
       sort_by,
       sort_dir,
       channel_filter,
       version_filter,
       all_revisions?,
       page
     )}
  end

  @impl true
  def handle_info({:change_processed, _payload}, socket) do
    {:noreply, assign(socket, :recent_changes, load_recent_changes(socket.assigns.package.id))}
  end

  @impl true
  def handle_info({:channel_revision_completed, _payload}, socket) do
    %{
      package: package,
      sort_by: sort_by,
      sort_dir: sort_dir,
      channel_filter: channel_filter,
      version_filter: version_filter,
      all_revisions?: all_revisions?,
      current_page: current_page
    } = socket.assigns

    {:noreply,
     assign_package_data(
       socket,
       package.id,
       sort_by,
       sort_dir,
       channel_filter,
       version_filter,
       all_revisions?,
       current_page
     )}
  end

  defp assign_package_data(
         socket,
         package_id,
         sort_by,
         sort_dir,
         channel_filter,
         version_filter,
         all_revisions?,
         page
       ) do
    offset = (page - 1) * 15
    package_events = load_package_events(package_id)

    channel_id = resolve_channel_id(channel_filter)

    {revisions, total_count, has_more?} =
      if all_revisions? do
        result =
          load_revisions(package_id, sort_by, sort_dir, channel_id, version_filter, offset)

        {result.results, result.count, result.more?}
      else
        {results, count} =
          Tracker.Nixpkgs.PackageRevision.version_changes_by_package(package_id,
            channel_id: channel_id,
            version: version_filter,
            sort_by: sort_by,
            sort_dir: sort_dir,
            limit: 15,
            offset: offset
          )

        {results, count, count > offset + 15}
      end

    total_pages = ceil(total_count / 15)

    socket
    |> assign(:package_events, package_events)
    |> assign(:revisions, revisions)
    |> assign(:has_prev_page?, offset > 0)
    |> assign(:has_next_page?, has_more?)
    |> assign(:total_pages, total_pages)
    |> assign(:current_page, page)
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

  defp load_revisions(package_id, sort_by, sort_dir, channel_id, version_filter, offset) do
    result =
      Tracker.Nixpkgs.PackageRevision.list_by_package!(package_id, channel_id, version_filter,
        query: [sort: [{sort_by, sort_dir}]],
        page: [offset: offset, count: true]
      )

    loaded_results = Ash.load!(result.results, channel_revision: [:channel])
    %{result | results: loaded_results}
  end

  defp load_recent_changes(package_id) do
    Tracker.Nixpkgs.Change.by_package!(package_id, page: [limit: 10]).results
  end

  defp load_family_siblings(%{package_family_id: nil}), do: []

  defp load_family_siblings(package) do
    Tracker.Nixpkgs.Package.family_siblings!(package.package_family_id, package.id)
  end

  defp load_variant_siblings(%{package_variant_group_id: nil}), do: []

  defp load_variant_siblings(package) do
    Tracker.Nixpkgs.Package.variant_siblings!(package.package_variant_group_id, package.id)
  end

  defp load_package_events(package_id) do
    Tracker.Nixpkgs.PackageEvent.list_by_package!(package_id)
    |> Ash.load!(channel_revision: [:channel])
  end

  defp load_channels do
    Tracker.Nixpkgs.Channel.nixos_channels!()
  end

  defp resolve_channel_id(""), do: nil
  defp resolve_channel_id(nil), do: nil

  defp resolve_channel_id(channel_name) do
    case Tracker.Nixpkgs.Channel.by_name(channel_name) do
      {:ok, channel} -> channel.id
      _ -> nil
    end
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

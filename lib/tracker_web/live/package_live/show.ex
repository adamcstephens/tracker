defmodule TrackerWeb.PackageLive.Show do
  use TrackerWeb, :live_view

  alias TrackerWeb.DataTable
  alias TrackerWeb.TableParams

  @table_opts [
    allowed_sorts: ~w(version channel_name revision_hash released_at)a,
    default_sort: :released_at,
    default_sort_dir: :desc
  ]

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

    <DataTable.data_table
      :if={@revisions != []}
      id="revisions"
      rows={@revisions}
      table_params={@table_params}
      base_path={"/packages/#{@package.attribute}"}
      total_pages={@total_pages}
      current_page={@current_page}
      has_prev_page?={@has_prev_page?}
      has_next_page?={@has_next_page?}
    >
      <:col :let={rev} field={:version} label="Version" sortable>
        <.github_version_link
          version={rev.version}
          position={@package.position}
          revision={rev_revision(rev)}
        />
      </:col>
      <:col :let={rev} field={:channel_name} label="Channel" sortable>
        {rev_channel(rev)}
      </:col>
      <:col :let={rev} field={:revision_hash} label="Revision" sortable>
        <.revision_link
          revision={rev_revision(rev)}
          channel={rev_channel(rev)}
        />
      </:col>
      <:col :let={rev} field={:released_at} label="Released" sortable>
        {format_released_at(rev_released_at(rev))}
      </:col>
    </DataTable.data_table>

    <p :if={@revisions == []}>
      No revisions found.
    </p>
    """
  end

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
    {:ok, socket}
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

    tp = TableParams.from_params(params, @table_opts)
    version_filter = params["version"] || ""
    all_revisions? = params["all_revisions"] == "true"

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Tracker.PubSub, "changes:updated")

      if socket.assigns.lens do
        Phoenix.PubSub.subscribe(
          Tracker.PubSub,
          "channel_revisions:#{socket.assigns.lens.channel.name}"
        )
      end
    end

    {:noreply,
     socket
     |> assign(:page_title, package.attribute)
     |> assign(:package, package)
     |> assign(:recent_changes, recent_changes)
     |> assign(:family_siblings, family_siblings)
     |> assign(:variant_siblings, variant_siblings)
     |> assign(:option_revisions, option_revisions)
     |> assign(:table_params, tp)
     |> assign(:version_filter, version_filter)
     |> assign(:all_revisions?, all_revisions?)
     |> load_revision_data()}
  end

  @impl true
  def handle_info(%Ash.Notifier.Notification{resource: Tracker.Nixpkgs.Change}, socket) do
    {:noreply, assign(socket, :recent_changes, load_recent_changes(socket.assigns.package.id))}
  end

  @impl true
  def handle_info({:channel_revision_completed, _payload}, socket) do
    {:noreply, load_revision_data(socket)}
  end

  def handle_info({:set_lens, channel_name, rev}, socket) do
    socket = TrackerWeb.LensHandlers.handle_lens_change(socket, channel_name, rev)
    {:noreply, load_revision_data(socket)}
  end

  defp extra_params(socket, overrides \\ %{}) do
    %{
      version: Map.get(overrides, :version, socket.assigns.version_filter),
      all_revisions: Map.get(overrides, :all_revisions, socket.assigns.all_revisions?)
    }
  end

  defp revisions_path(package_name, tp, extra_overrides) do
    extras =
      %{
        version: Map.get(extra_overrides, :version, ""),
        all_revisions: Map.get(extra_overrides, :all_revisions, false)
      }

    TableParams.to_path(tp, "/packages/#{package_name}", extras)
  end

  defp load_revision_data(socket) do
    package_id = socket.assigns.package.id
    tp = socket.assigns.table_params
    version_filter = socket.assigns.version_filter
    all_revisions? = socket.assigns.all_revisions?
    channel_id = TrackerWeb.Lens.channel_id(socket.assigns.lens)

    package_events = load_package_events(package_id)

    {revisions, total_count, has_more?} =
      if all_revisions? do
        result =
          load_revisions(
            package_id,
            tp.sort_by,
            tp.sort_dir,
            channel_id,
            version_filter,
            tp.offset
          )

        {result.results, result.count, result.more?}
      else
        {results, count} =
          Tracker.Nixpkgs.PackageRevision.version_changes_by_package(package_id,
            channel_id: channel_id,
            version: version_filter,
            sort_by: tp.sort_by,
            sort_dir: tp.sort_dir,
            limit: tp.page_size,
            offset: tp.offset
          )

        {results, count, count > tp.offset + tp.page_size}
      end

    total_pages = ceil(total_count / tp.page_size)

    socket
    |> assign(:package_events, package_events)
    |> assign(:revisions, revisions)
    |> assign(:has_prev_page?, tp.offset > 0)
    |> assign(:has_next_page?, has_more?)
    |> assign(:total_pages, total_pages)
    |> assign(:current_page, tp.page)
  end

  @impl true
  def handle_event("sort", %{"field" => field}, socket) do
    tp = socket.assigns.table_params
    new_sort_by = TableParams.from_params(%{"sort_by" => field}, @table_opts).sort_by

    new_sort_dir =
      if tp.sort_by == new_sort_by, do: TableParams.toggle_dir(tp.sort_dir), else: :asc

    new_tp = %{tp | sort_by: new_sort_by, sort_dir: new_sort_dir, page: 1, offset: 0}

    {:noreply,
     push_patch(socket,
       to: revisions_path(socket.assigns.package.attribute, new_tp, extra_params(socket))
     )}
  end

  @impl true
  def handle_event("filter", params, socket) do
    version = Map.get(params, "version", "")
    all_revisions? = Map.get(params, "all_revisions", "false") == "true"
    tp = %{socket.assigns.table_params | page: 1, offset: 0}

    {:noreply,
     push_patch(socket,
       to:
         revisions_path(socket.assigns.package.attribute, tp, %{
           version: version,
           all_revisions: all_revisions?
         })
     )}
  end

  @impl true
  def handle_event("next-page", _params, socket) do
    tp = socket.assigns.table_params

    {:noreply,
     push_patch(socket,
       to:
         revisions_path(
           socket.assigns.package.attribute,
           %{tp | page: tp.page + 1},
           extra_params(socket)
         )
     )}
  end

  @impl true
  def handle_event("prev-page", _params, socket) do
    tp = socket.assigns.table_params

    {:noreply,
     push_patch(socket,
       to:
         revisions_path(
           socket.assigns.package.attribute,
           %{tp | page: max(tp.page - 1, 1)},
           extra_params(socket)
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
end

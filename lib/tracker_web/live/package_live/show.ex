defmodule TrackerWeb.PackageLive.Show do
  use TrackerWeb, :live_view

  alias Tracker.Notifications.PackageSubscription
  alias TrackerWeb.PageSearch
  alias TrackerWeb.Pagination
  alias TrackerWeb.RowList
  alias TrackerWeb.SectionHeader
  alias TrackerWeb.TableParams

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      {@package.attribute}
      <:actions>
        <a
          id="feed-link"
          href={"/feeds/packages/#{@package.attribute}"}
          phx-hook="CopyLink"
          title="Copy the Atom feed URL"
          style="display: flex; align-items: center;"
        >
          <img src="/images/feed.svg" alt="Atom feed" width="20" height="20" />
        </a>
        <button
          :if={@current_user}
          id="subscribe-toggle"
          type="button"
          phx-click="toggle-subscription"
        >
          {if @subscribed?, do: "Unsubscribe", else: "Subscribe"}
        </button>
      </:actions>
    </.header>

    <p :if={@package_meta.description}>{@package_meta.description}</p>

    <p :if={availability_flags(@package_meta) != []}>
      <mark :for={flag <- availability_flags(@package_meta)}>{flag}</mark>
    </p>

    <ul :if={@package_meta.known_vulnerabilities not in [nil, []]}>
      <li :for={vuln <- @package_meta.known_vulnerabilities}><mark>{vuln}</mark></li>
    </ul>

    <p :if={@package_meta.long_description} style="white-space: pre-line;">
      {@package_meta.long_description}
    </p>

    <.list>
      <:item title="Attribute">{@package.attribute}</:item>
      <:item :if={@package_meta.homepage} title="Homepage">
        <span :for={url <- @package_meta.homepage}>
          <a href={url} target="_blank" rel="noopener noreferrer">
            {url}
          </a>
        </span>
      </:item>
      <:item :if={@package_meta.position} title="Position">
        <.nixpkgs_position position={@package_meta.position} />
      </:item>
      <:item :if={@package_meta.licenses} title="License">
        {Enum.join(@package_meta.licenses, ", ")}
      </:item>
      <:item :if={@package_meta.main_program} title="Main program">
        <code>{@package_meta.main_program}</code>
      </:item>
      <:item :if={@package_meta.outputs} title="Outputs">
        {Enum.join(@package_meta.outputs, ", ")}<span :if={@package_meta.default_output}> (default: {@package_meta.default_output})</span>
      </:item>
      <:item :if={@package_meta.changelog} title="Changelog">
        <span :for={url <- @package_meta.changelog}>
          <a href={url} target="_blank" rel="noopener noreferrer">
            {url}
          </a>
        </span>
      </:item>
      <:item :if={@package_meta.download_page} title="Download page">
        <a href={@package_meta.download_page} target="_blank" rel="noopener noreferrer">
          {@package_meta.download_page}
        </a>
      </:item>
      <:item :if={@package_meta.source_provenance} title="Source provenance">
        {Enum.join(@package_meta.source_provenance, ", ")}
      </:item>
    </.list>

    <details :if={@package_meta.platforms not in [nil, []]}>
      <summary>Platforms ({length(@package_meta.platforms)})</summary>
      <p>{Enum.join(@package_meta.platforms, ", ")}</p>
    </details>

    <details :if={@package_meta.bad_platforms not in [nil, []]}>
      <summary>Bad platforms ({length(@package_meta.bad_platforms)})</summary>
      <p>{Enum.join(@package_meta.bad_platforms, ", ")}</p>
    </details>

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

    <section :if={@linked_options != []}>
      <h2>NixOS Options</h2>
      <ul>
        <li :for={opt <- @linked_options}>
          <.link navigate={~p"/options/#{opt.name}"}>{opt.name}</.link>
          <% rev = Map.get(@option_revisions, opt.id) %>
          <small :if={rev}>
            <span :if={rev.type}> ({rev.type})</span>
            <span :if={rev.description}>{rev.description}</span>
          </small>
        </li>
      </ul>
    </section>

    <section :if={@recent_changes != []}>
      <SectionHeader.section_header title="Recent Changes" count={length(@recent_changes)} />
      <RowList.row_list id="recent-changes" stacked>
        <RowList.row
          :for={change <- @recent_changes}
          mode={:link}
          navigate={~p"/changes/#{change.number}"}
        >
          <:label>
            <span class="row-num">#{change.number}</span> {change.title}
          </:label>
          <:meta>
            <span>{change.author}</span>
            <span>{format_released_at(change.merged_at)}</span>
          </:meta>
        </RowList.row>
      </RowList.row_list>
    </section>

    <section :if={@package_events != []}>
      <SectionHeader.section_header title="Lifecycle Events" count={length(@package_events)} />
      <RowList.row_list id="lifecycle-events" stacked>
        <RowList.row :for={event <- @package_events}>
          <:leading>
            <mark :if={event.type == :added}>added</mark>
            <del :if={event.type == :removed}>removed</del>
          </:leading>
          <:label>{event.channel_revision.channel.name}</:label>
          <:meta>
            <.revision_link
              revision={event.channel_revision.revision}
              channel={event.channel_revision.channel.name}
            />
            <span>{format_released_at(event.channel_revision.released_at)}</span>
          </:meta>
        </RowList.row>
      </RowList.row_list>
    </section>

    <SectionHeader.section_header title="Revisions" count={@revision_count}>
      <:controls>
        <form
          id="revision-filters"
          method="get"
          action={~p"/packages/#{@package.attribute}"}
          phx-change="filter"
          phx-submit="filter"
          class="revision-filters"
        >
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
        </form>
      </:controls>
    </SectionHeader.section_header>

    <RowList.row_list :if={@revisions != []} id="revisions" stacked>
      <RowList.row :for={rev <- @revisions}>
        <:label>
          <.github_version_link
            version={rev.version}
            position={@package_meta.position}
            revision={rev_revision(rev)}
          />
        </:label>
        <:sublabel>{rev_channel(rev)}</:sublabel>
        <:meta>
          <.revision_link revision={rev_revision(rev)} channel={rev_channel(rev)} />
          <span>{format_released_at(rev_released_at(rev))}</span>
        </:meta>
      </RowList.row>
    </RowList.row_list>

    <Pagination.controls
      total_pages={@total_pages}
      current_page={@current_page}
      has_prev_page?={@has_prev_page?}
      has_next_page?={@has_next_page?}
      prev_path={
        revisions_path(
          @package.attribute,
          %{@table_params | page: @current_page - 1},
          %{version: @version_filter, all_revisions: @all_revisions?}
        )
      }
      next_path={
        revisions_path(
          @package.attribute,
          %{@table_params | page: @current_page + 1},
          %{version: @version_filter, all_revisions: @all_revisions?}
        )
      }
    />

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

  alias Tracker.Nixpkgs.PackageHistory.VersionChange

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
    {:ok,
     socket
     |> assign_new(:current_user, fn -> nil end)
     |> assign(:subscribed?, false)}
  end

  # The page is not revision-scoped, so options come from link spans still open
  # in any channel — one option can be linked in several, hence the dedup.
  defp linked_options(package) do
    package.id
    |> List.wrap()
    |> Tracker.Nixpkgs.OptionPackageSpan.open_for_packages!()
    |> Enum.map(& &1.option)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.name)
  end

  @impl true
  def handle_params(%{"name" => name} = params, _url, socket) do
    package =
      Tracker.Nixpkgs.Package.get_by_attribute!(name,
        load: [:maintainers, :teams]
      )

    family_siblings = package |> load_family_siblings() |> decorate_siblings()
    variant_siblings = load_variant_siblings(package)
    linked_options = linked_options(package)
    # The linked-options section shows each option's current metadata, served
    # from its open span (most-recent across channels).
    option_revisions =
      linked_options
      |> Enum.map(& &1.id)
      |> Tracker.Nixpkgs.OptionHistory.current_metadata()

    tp = TableParams.from_params(params)
    version_filter = params["version"] || ""
    all_revisions? = params["all_revisions"] == "true"

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Tracker.PubSub, "changes:updated")

      if socket.assigns.lens do
        scope =
          if socket.assigns.lens.all?, do: "any", else: socket.assigns.lens.channel.id

        Phoenix.PubSub.subscribe(
          Tracker.PubSub,
          "channel_revisions:#{scope}:completed"
        )
      end
    end

    {:noreply,
     socket
     |> assign(:page_title, package.attribute)
     |> assign(:package, package)
     |> assign(:subscribed?, package_subscribed?(socket.assigns.current_user, package.id))
     |> assign(:family_siblings, family_siblings)
     |> assign(:variant_siblings, variant_siblings)
     |> assign(:linked_options, linked_options)
     |> assign(:option_revisions, option_revisions)
     |> assign(:table_params, tp)
     |> assign(:version_filter, version_filter)
     |> assign(:all_revisions?, all_revisions?)
     |> assign(:page_search, %PageSearch{
       mode: :passthrough,
       action: "/packages",
       value: Map.get(params, "search", "")
     })
     |> load_revision_data()}
  end

  @impl true
  def handle_info(%Ash.Notifier.Notification{resource: Tracker.Nixpkgs.Change}, socket) do
    {:noreply, load_revision_data(socket)}
  end

  @impl true
  def handle_info(
        %Ash.Notifier.Notification{
          resource: Tracker.Nixpkgs.ChannelRevision,
          action: %{name: :record_result}
        },
        socket
      ) do
    {:noreply, load_revision_data(socket)}
  end

  def handle_info({:set_lens, channel_name, rev}, socket) do
    socket = TrackerWeb.LensHandlers.handle_lens_change(socket, channel_name, rev)
    {:noreply, load_revision_data(socket)}
  end

  defp package_subscribed?(nil, _package_id), do: false

  defp package_subscribed?(user, package_id) do
    case PackageSubscription.find(package_id, nil, actor: user) do
      {:ok, nil} -> false
      {:ok, _subscription} -> true
    end
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
    channel_name = TrackerWeb.Lens.channel_name(socket.assigns.lens)

    recent_changes = load_recent_changes(package_id, channel_name)
    package_events = load_package_events(package_id, channel_id)

    {revisions, total_count, has_more?} =
      if all_revisions? do
        result =
          load_revisions(
            package_id,
            channel_id,
            version_filter,
            tp.offset,
            tp.page_size
          )

        {result.results, result.count, result.more?}
      else
        {results, count} =
          Tracker.Nixpkgs.PackageHistory.version_changes_by_package(package_id,
            channel_id: channel_id,
            version: version_filter,
            sort_by: :released_at,
            sort_dir: :desc,
            limit: tp.page_size,
            offset: tp.offset
          )

        {results, count, count > tp.offset + tp.page_size}
      end

    total_pages = ceil(total_count / tp.page_size)

    socket
    |> assign(:package_meta, load_current_meta(package_id, channel_id))
    |> assign(:recent_changes, recent_changes)
    |> assign(:package_events, package_events)
    |> assign(:revisions, revisions)
    |> assign(:revision_count, total_count)
    |> assign(:has_prev_page?, tp.offset > 0)
    |> assign(:has_next_page?, has_more?)
    |> assign(:total_pages, total_pages)
    |> assign(:current_page, tp.page)
  end

  @impl true
  def handle_event("toggle-subscription", _params, socket) do
    %{current_user: user, package: package} = socket.assigns

    subscribed? =
      case PackageSubscription.find(package.id, nil, actor: user) do
        {:ok, nil} ->
          {:ok, _subscription} = PackageSubscription.subscribe(package.id, nil, actor: user)
          true

        {:ok, subscription} ->
          :ok = PackageSubscription.destroy(subscription, actor: user)
          false
      end

    {:noreply, assign(socket, :subscribed?, subscribed?)}
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

  defp load_revisions(package_id, channel_id, version_filter, offset, page_size) do
    Tracker.Nixpkgs.PackageHistory.revisions_by_package(package_id, channel_id,
      version: version_filter,
      sort_by: :released_at,
      sort_dir: :desc,
      limit: page_size,
      offset: offset
    )
  end

  defp load_recent_changes(package_id, channel_name) do
    Tracker.Nixpkgs.Change.by_package!(package_id, channel_name, page: [limit: 10]).results
  end

  defp load_family_siblings(%{package_family_id: nil}), do: []

  defp load_family_siblings(package) do
    Tracker.Nixpkgs.Package.family_siblings!(package.package_family_id, package.id)
  end

  # Family-sibling display labels: package_set / set_version are derived from the
  # attribute, so no current-state lookup is needed.
  defp decorate_siblings(siblings) do
    Enum.map(siblings, fn sibling ->
      parsed = Tracker.Nixpkgs.PackageSetMapping.parse(sibling.attribute)

      %{
        attribute: sibling.attribute,
        package_set: parsed.package_set,
        set_version: parsed.set_version
      }
    end)
  end

  @availability_flags [:broken, :unfree, :insecure, :unsupported]

  defp availability_flags(package_meta) do
    Enum.filter(@availability_flags, &(Map.get(package_meta, &1) == true))
  end

  # Current package metadata is served from the open span in the lens channel;
  # the metadata channel is the fallback for the all-channels lens, packages
  # absent from the lens channel, and spans written before metadata was
  # ingested on every channel.
  defp load_current_meta(package_id, lens_channel_id) do
    span = lens_meta_span(package_id, lens_channel_id) || metadata_channel_span(package_id)

    Map.new(
      Tracker.Nixpkgs.PackageHistory.metadata_fields(),
      &{&1, span && Map.get(span, &1)}
    )
  end

  defp lens_meta_span(_package_id, nil), do: nil

  defp lens_meta_span(package_id, channel_id) do
    case current_meta_span(package_id, channel_id) do
      nil -> nil
      span -> if Tracker.Nixpkgs.PackageHistory.metadata_missing?(span), do: nil, else: span
    end
  end

  defp metadata_channel_span(package_id) do
    case metadata_channel_id() do
      nil -> nil
      channel_id -> current_meta_span(package_id, channel_id)
    end
  end

  defp current_meta_span(package_id, channel_id) do
    channel_id
    |> Tracker.Nixpkgs.PackageHistory.current_metadata([package_id])
    |> Map.get(package_id)
  end

  defp metadata_channel_id do
    case Tracker.Nixpkgs.Channel.by_name(Tracker.Ingestion.StepGraph.metadata_channel()) do
      {:ok, channel} -> channel.id
      _ -> nil
    end
  end

  defp load_variant_siblings(%{package_variant_group_id: nil}), do: []

  defp load_variant_siblings(package) do
    Tracker.Nixpkgs.Package.variant_siblings!(package.package_variant_group_id, package.id)
  end

  defp load_package_events(package_id, channel_id) do
    Tracker.Nixpkgs.PackageHistory.events_by_package(package_id, channel_id)
  end
end

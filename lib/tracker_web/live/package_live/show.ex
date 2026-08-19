defmodule TrackerWeb.PackageLive.Show do
  use TrackerWeb, :live_view

  alias Tracker.Nixpkgs.PackageHistory.Removal
  alias Tracker.Nixpkgs.PackageHistory.VersionChange
  alias Tracker.Notifications.PackageSubscription
  alias TrackerWeb.NotificationPresenter
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
      <span :if={@removal} class="pill pill-removed" title={removal_title(@removal, @lens)}>
        <span class="dot" aria-hidden="true"></span>{removal_label(@removal, @lens)}
      </span>
      <span
        :if={@absent_from_lens_channel?}
        class="pill pill-removed"
        title={absent_title(@lens)}
      >
        <span class="dot" aria-hidden="true"></span>{absent_label(@lens)}
      </span>
      <span
        :if={@absent_from_live_channels?}
        class="pill pill-removed"
        title="Gone from every channel still taking revisions. It may still be present in a retired one."
      >
        <span class="dot" aria-hidden="true"></span>not in any current channel
      </span>
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

    <form
      :if={@subscribed?}
      id="subscription-events"
      class="sub-events"
      phx-change="set-subscription-events"
    >
      <span class="sub-events__label">Notify me about</span>
      <label :for={type <- NotificationPresenter.package_type_order()}>
        <input
          type="checkbox"
          name="events[]"
          value={type}
          checked={type in @subscription_events}
        />
        {NotificationPresenter.type_filter_label(type)}
      </label>
    </form>

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
        <.nixpkgs_position position={@package_meta.position} revision={@meta_revision} />
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
          <.revision_row_label rev={rev} />
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

  # A removal is the end of a version's run, not a version of its own — it links
  # nowhere and carries no position.
  defp revision_row_label(%{rev: %Removal{}} = assigns) do
    ~H"""
    <span class="pill pill-removed">
      <span class="dot" aria-hidden="true"></span>removed
    </span>
    """
  end

  defp revision_row_label(assigns) do
    ~H"""
    <.github_version_link
      version={@rev.version}
      position={@rev.position}
      revision={rev_revision(@rev)}
    />
    <mark :if={rev_added?(@rev)}>added</mark>
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
      href={"https://github.com/NixOS/nixpkgs/blob/#{@revision}/#{@path}" <> if(@line, do: "#L#{@line}", else: "")}
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

  defp rev_channel(%VersionChange{channel_name: channel_name}), do: channel_name
  defp rev_channel(%Removal{channel_name: channel_name}), do: channel_name
  defp rev_channel(%{channel_revision: %{channel: %{name: name}}}), do: name

  defp rev_revision(%VersionChange{revision: revision}), do: revision
  defp rev_revision(%Removal{revision: revision}), do: revision
  defp rev_revision(%{channel_revision: %{revision: revision}}), do: revision

  defp rev_released_at(%VersionChange{released_at: released_at}), do: released_at
  defp rev_released_at(%Removal{released_at: released_at}), do: released_at
  defp rev_released_at(%{channel_revision: %{released_at: released_at}}), do: released_at

  defp rev_added?(%{added?: added?}), do: added?

  # The badge sides with the lists, which are channel-scoped, while the metadata
  # panel above resolves at the pin. Naming where the removal sits relative to
  # the pinned view is what keeps the two readable together.
  defp removal_label(removal, lens) do
    if pinned_before?(removal, lens), do: "removed later", else: "removed"
  end

  defp removal_title(removal, lens) do
    sentence =
      "Removed from #{removal.channel_name} at #{String.slice(removal.revision, 0, 7)} on #{format_released_at(removal.released_at)}"

    if pinned_before?(removal, lens),
      do: sentence <> ", after the revision this page is pinned to.",
      else: sentence <> "."
  end

  # A package absent at the pin may still be present today — it can sit before
  # its own addition, or in a gap between a removal and a re-addition — so the
  # pinned copy scopes itself to the revision rather than to the channel.
  defp absent_label(lens) do
    case TrackerWeb.Lens.pinned_at(lens) do
      nil -> "not in #{TrackerWeb.Lens.channel_name(lens)}"
      _at -> "not in #{TrackerWeb.Lens.channel_name(lens)} at this revision"
    end
  end

  defp absent_title(lens) do
    channel = TrackerWeb.Lens.channel_name(lens)

    case TrackerWeb.Lens.pinned_at(lens) do
      nil ->
        "This package has never been in #{channel}."

      _at ->
        "This package is not in #{channel} at the revision this page is pinned to. It may be present now."
    end
  end

  defp pinned_before?(removal, lens) do
    case TrackerWeb.Lens.pinned_at(lens) do
      nil -> false
      at -> DateTime.compare(at, removal.released_at) == :lt
    end
  end

  defp format_released_at(nil), do: "-"
  defp format_released_at(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign_new(:current_user, fn -> nil end)
     |> assign_subscription_state(nil)}
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
     |> assign_subscription(socket.assigns.current_user, package.id)
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

  defp assign_subscription(socket, nil, _package_id),
    do: assign_subscription_state(socket, nil)

  defp assign_subscription(socket, user, package_id) do
    {:ok, subscription} = PackageSubscription.find(package_id, nil, actor: user)
    assign_subscription_state(socket, subscription)
  end

  defp assign_subscription_state(socket, subscription) do
    socket
    |> assign(:subscribed?, not is_nil(subscription))
    |> assign(:subscription_events, (subscription && subscription.events) || [])
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
            removals?: true,
            limit: tp.page_size,
            offset: tp.offset
          )

        {results, count, count > tp.offset + tp.page_size}
      end

    total_pages = ceil(total_count / tp.page_size)

    socket
    |> assign_removal_status(package_id, channel_id)
    |> assign_current_meta(package_id, channel_id, TrackerWeb.Lens.pinned_at(socket.assigns.lens))
    |> assign(:recent_changes, recent_changes)
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

    subscription =
      case PackageSubscription.find(package.id, nil, actor: user) do
        {:ok, nil} ->
          {:ok, subscription} = PackageSubscription.subscribe(package.id, nil, actor: user)
          subscription

        {:ok, subscription} ->
          :ok = PackageSubscription.destroy(subscription, actor: user)
          nil
      end

    {:noreply, assign_subscription_state(socket, subscription)}
  end

  # An empty selection means "notify me about nothing", which is an
  # unsubscribe; the resource itself requires at least one event.
  @impl true
  def handle_event("set-subscription-events", params, socket) do
    %{current_user: user, package: package} = socket.assigns
    {:ok, subscription} = PackageSubscription.find(package.id, nil, actor: user)

    subscription =
      case Map.get(params, "events", []) do
        [] ->
          :ok = PackageSubscription.destroy(subscription, actor: user)
          nil

        events ->
          {:ok, updated} =
            PackageSubscription.set_events(
              subscription,
              Enum.map(events, &String.to_existing_atom/1),
              actor: user
            )

          updated
      end

    {:noreply, assign_subscription_state(socket, subscription)}
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

  # Package metadata is served from the span in the lens channel — the one valid
  # at the lens's pinned revision, or the open one when unpinned. Only the
  # all-channels lens falls back to the metadata channel, having no channel of
  # its own to describe; a selected channel shows its own span or nothing,
  # rather than passing another channel's data off as its own.
  defp assign_current_meta(socket, package_id, nil, pinned_at) do
    socket
    |> assign_meta(metadata_channel_span(package_id, pinned_at), pinned_at)
    |> assign(:absent_from_lens_channel?, false)
  end

  defp assign_current_meta(socket, package_id, lens_channel_id, pinned_at) do
    span = meta_span(package_id, lens_channel_id, pinned_at)

    socket
    |> assign_meta(span, pinned_at)
    |> assign(:absent_from_lens_channel?, is_nil(span) and is_nil(socket.assigns.removal))
  end

  defp assign_meta(socket, span, pinned_at) do
    meta =
      Map.new(
        Tracker.Nixpkgs.PackageHistory.metadata_fields(),
        &{&1, span && Map.get(span, &1)}
      )

    socket
    |> assign(:package_meta, meta)
    |> assign(:meta_revision, meta_revision(span, pinned_at))
  end

  # The panel describes one channel at one instant, so its file link points at
  # that channel's revision there — the pinned ref itself when the span came
  # from the lens channel, otherwise the fallback channel's revision at the same
  # instant. A span always sits at or after a revision of its own channel.
  defp meta_revision(nil, _pinned_at), do: nil

  defp meta_revision(span, pinned_at) do
    {:ok, revision} = Tracker.Nixpkgs.ChannelRevision.latest_at(span.channel_id, pinned_at)
    revision.revision
  end

  defp metadata_channel_span(package_id, pinned_at) do
    case metadata_channel_id() do
      nil -> nil
      channel_id -> meta_span(package_id, channel_id, pinned_at)
    end
  end

  defp meta_span(package_id, channel_id, nil) do
    channel_id
    |> Tracker.Nixpkgs.PackageHistory.current_metadata([package_id])
    |> Map.get(package_id)
  end

  defp meta_span(package_id, channel_id, pinned_at) do
    channel_id
    |> Tracker.Nixpkgs.PackageHistory.metadata_at(pinned_at, [package_id])
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

  # The status answers the question the lens is asking. Under one channel that
  # is "has it left this one" — terminal removals only, since a package removed
  # and re-added is present. With no lens channel there is none to describe, so
  # it broadens to "does this package still exist anywhere".
  defp assign_removal_status(socket, package_id, nil) do
    socket
    |> assign(:removal, nil)
    |> assign(
      :absent_from_live_channels?,
      Tracker.Nixpkgs.PackageHistory.absent_from_live_channels?(package_id)
    )
  end

  defp assign_removal_status(socket, package_id, channel_id) do
    socket
    |> assign(:removal, Tracker.Nixpkgs.PackageHistory.terminal_removal(package_id, channel_id))
    |> assign(:absent_from_live_channels?, false)
  end
end

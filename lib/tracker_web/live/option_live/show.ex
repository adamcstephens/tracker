defmodule TrackerWeb.OptionLive.Show do
  use TrackerWeb, :live_view

  import TrackerWeb.CodeHighlight

  alias TrackerWeb.DataTable
  alias TrackerWeb.PageSearch

  # Inline so it works on dead renders too — anonymous visitors don't load
  # app.js (see TrackerWeb.Plug.InteractiveUI), so a phx-hook would never run.
  # Copies data-copy when present (the attribute path), else the link's URL.
  # The class is "copied", not "is-copied" — the global .is-copied rule
  # renders a floating "Copied!" bubble; here the icon swaps in place.
  defp copy_onclick do
    """
    event.preventDefault(); event.stopPropagation(); \
    navigator.clipboard.writeText(this.dataset.copy || this.href); \
    this.classList.add('copied'); clearTimeout(this._copyTimer); \
    this._copyTimer = setTimeout(() => this.classList.remove('copied'), 1400)\
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="option-show">
      <h1 :if={@prefix != ""} class="opt-pathbar" aria-label={@prefix}>
        <%= for {seg, cumulative, last?} <- crumbs(@prefix) do %>
          <.link :if={!last?} navigate={~p"/options/#{cumulative}"} class="crumb-link">
            {seg}
          </.link>
          <span :if={last?} class="crumb-current" aria-current="page">{seg}</span>
          <span :if={!last?} class="crumb-sep" aria-hidden="true">.</span>
        <% end %>
        <a
          href={~p"/options/#{@prefix}"}
          class="opt-copy"
          data-copy={@prefix}
          onclick={copy_onclick()}
          title="Copy attribute path"
          aria-label={"Copy attribute path #{@prefix}"}
        >
          <.copy_icon />
          <.check_icon />
        </a>
      </h1>

      <p :if={@select_channel?} class="opt-select-channel">
        Options are channel-specific. Select a channel from the picker above to browse them.
      </p>

      <p :if={@channel_unavailable?}>
        The {@channel} channel doesn't have options data.
      </p>

      <p :if={!@channel_unavailable? and @nothing_here?}>
        No options match this prefix in {@channel}.
      </p>

      <section :if={@subgroups != []}>
        <h2>Children</h2>
        <div class="opt-children">
          <.link
            :for={{group, count} <- @subgroups}
            navigate={~p"/options/#{group}"}
            class="child-card"
          >
            <span class="name">
              <span :if={@prefix != ""} class="leading">{@prefix}.</span><span class="tail">{tail(
                group,
                @prefix
              )}</span>
            </span>
            <span class="right">
              <span>{count} options</span>
              <span class="arrow" aria-hidden="true">→</span>
            </span>
          </.link>
        </div>
      </section>

      <section :if={@matches != []}>
        <h2>Matching options</h2>
        <.table id="matching-options" rows={@matches}>
          <:col :let={rev} label="Option">
            <.link navigate={~p"/options/#{rev.option.name}"}>{rev.option.name}</.link>
          </:col>
          <:col :let={rev} label="Group">
            <.link
              :if={parent_prefix(rev.option.name)}
              navigate={~p"/options/#{parent_prefix(rev.option.name)}"}
            >
              {parent_prefix(rev.option.name)}
            </.link>
          </:col>
        </.table>

        <DataTable.pagination
          total_pages={@total_pages}
          current_page={@current_page}
          has_prev_page?={@has_prev_page?}
          has_next_page?={@has_next_page?}
          prev_path={options_path(@prefix, @search, @current_page - 1)}
          next_path={options_path(@prefix, @search, @current_page + 1)}
        />
      </section>

      <section :if={@leaf_options != []}>
        <h2>Options at this prefix</h2>
        <ul id="options-list" class="opt-list" phx-hook="AnchorExpand">
          <li :for={rev <- @leaf_options}>
            <details id={"opt-#{rev.option.name}"} open={length(@leaf_options) == 1}>
              <summary>
                <span class="opt-name">
                  <%= if rev.option.name == @prefix do %>
                    <em class="tail">self</em>
                  <% else %>
                    <span :if={@prefix != ""} class="leading">{@prefix}.</span><span class="tail">{tail(
                      rev.option.name,
                      @prefix
                    )}</span>
                  <% end %>
                </span>
                <span class="opt-type">
                  {rev.type}<span :if={rev.read_only}> (read-only)</span>
                </span>
                <button
                  type="button"
                  class="opt-share"
                  data-copy={rev.option.name}
                  onclick={copy_onclick()}
                  title="Copy attribute path"
                  aria-label={"Copy attribute path #{rev.option.name}"}
                >
                  <.copy_icon />
                  <.check_icon />
                </button>
                <a
                  href={~p"/options/#{rev.option.name}"}
                  class="opt-share"
                  onclick={copy_onclick()}
                  title="Copy share link"
                  aria-label={"Copy link to #{rev.option.name}"}
                >
                  <.share_icon />
                  <.check_icon />
                </a>
              </summary>

              <dl class="opt-detail">
                <dt :if={rev.type}>Type</dt>
                <dd :if={rev.type}>
                  {rev.type}
                  <span :if={rev.read_only} class="read-only">(read-only)</span>
                </dd>

                <dt :if={rev.description}>Description</dt>
                <dd :if={rev.description}><.nixos_markdown text={rev.description} /></dd>

                <dt :if={rev.default}>Default</dt>
                <dd :if={rev.default}><.code_block code={rev.default} /></dd>

                <dt :if={rev.example}>Example</dt>
                <dd :if={rev.example}><.code_block code={rev.example} /></dd>

                <dt :if={option_packages(rev) != []}>Packages</dt>
                <dd :if={option_packages(rev) != []}>
                  <span :for={pkg <- option_packages(rev)}>
                    <.link navigate={~p"/packages/#{pkg.attribute}"}>{pkg.attribute}</.link>
                  </span>
                </dd>
                <dt :if={files_for(@files_by_option, rev.option_id) != []}>Defined in</dt>
                <dd :if={files_for(@files_by_option, rev.option_id) != []}>
                  <span :for={file <- files_for(@files_by_option, rev.option_id)}>
                    <.declaration_link path={file.path} channel_revision={@channel_revision} />
                  </span>
                </dd>
              </dl>
            </details>
          </li>
        </ul>
      </section>

      <section :if={@files != [] and @leaf_options == []}>
        <h2>Defined in</h2>
        <ul class="opt-defined">
          <li :for={file <- @files}>
            <.declaration_link path={file.path} channel_revision={@channel_revision} />
          </li>
        </ul>
      </section>

      <section :if={@recent_prs != []}>
        <h2>Recent PRs touching these files</h2>
        <ul class="opt-prs">
          <li :for={pr <- @recent_prs}>
            <.link navigate={~p"/changes/#{pr.number}"} class="prnum">#{pr.number}</.link>
            <span class="title">{pr.title}</span>
            <span :if={pr.state} class={"pill pill-#{pr.state}"}>
              <span class="dot" aria-hidden="true"></span>
              {pr.state}
            </span>
          </li>
        </ul>
      </section>
    </div>
    """
  end

  defp check_icon(assigns) do
    ~H"""
    <svg
      class="opt-check-icon"
      viewBox="0 0 24 24"
      width="14"
      height="14"
      fill="none"
      stroke="currentColor"
      stroke-width="1.8"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <polyline points="20 6 9 17 4 12" />
    </svg>
    """
  end

  defp copy_icon(assigns) do
    ~H"""
    <svg
      class="opt-share-icon"
      viewBox="0 0 24 24"
      width="14"
      height="14"
      fill="none"
      stroke="currentColor"
      stroke-width="1.8"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <rect x="9" y="9" width="13" height="13" rx="2" ry="2" />
      <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
    </svg>
    """
  end

  defp share_icon(assigns) do
    ~H"""
    <svg
      class="opt-share-icon"
      viewBox="0 0 24 24"
      width="14"
      height="14"
      fill="none"
      stroke="currentColor"
      stroke-width="1.8"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <path d="M10 13a5 5 0 0 0 7.07 0l3-3a5 5 0 1 0-7.07-7.07l-1.5 1.5" />
      <path d="M14 11a5 5 0 0 0-7.07 0l-3 3a5 5 0 1 0 7.07 7.07l1.5-1.5" />
    </svg>
    """
  end

  defp crumbs(prefix) do
    segments = String.split(prefix, ".")
    last_index = length(segments) - 1

    segments
    |> Enum.with_index()
    |> Enum.map(fn {seg, i} ->
      cumulative = segments |> Enum.take(i + 1) |> Enum.join(".")
      {seg, cumulative, i == last_index}
    end)
  end

  defp tail(name, ""), do: name
  defp tail(name, prefix), do: String.slice(name, String.length(prefix) + 1, String.length(name))

  defp option_packages(%{option: %{packages: packages}}),
    do: packages

  defp option_packages(_), do: []

  defp declaration_link(%{channel_revision: %{revision: revision}} = assigns) do
    assigns =
      assign(assigns, :url, "https://github.com/NixOS/nixpkgs/blob/#{revision}/#{assigns.path}")

    ~H"""
    <a href={@url} target="_blank" rel="noopener noreferrer"><code>{@path}</code></a>
    """
  end

  defp declaration_link(assigns) do
    ~H"""
    <code>{@path}</code>
    """
  end

  # Renders the nixos-render-docs CommonMark dialect used in NixOS option
  # descriptions: standard Markdown plus fenced-div admonitions and inline
  # `{role}` spans.
  defp nixos_markdown(assigns) do
    html = markdown_to_html(assigns.text)
    assigns = assign(assigns, :html, html)

    ~H"""
    <div class="nixos-markdown">{Phoenix.HTML.raw(@html)}</div>
    """
  end

  @admonition_classes %{
    "note" => "NOTE",
    "tip" => "TIP",
    "important" => "IMPORTANT",
    "warning" => "WARNING",
    "caution" => "CAUTION"
  }

  defp markdown_to_html(text) do
    text
    |> preprocess_admonitions()
    |> preprocess_inline_roles()
    |> MDEx.to_html!(
      extension: [alerts: true, autolink: true],
      sanitize: MDEx.Document.default_sanitize_options(),
      syntax_highlight: [engine: :lumis, opts: [formatter: :html_linked]]
    )
  end

  # nixos-render-docs fenced divs (`::: {.note} ... :::`) map 1:1 onto GFM
  # alert types, which MDEx already renders as styled callouts. Some
  # descriptions never close the fence before the string ends (the upstream
  # doc pipeline treats EOF as an implicit close), so the closing `:::` is
  # optional here too.
  defp preprocess_admonitions(text) do
    Regex.replace(
      ~r/^:::[ \t]*\{\.(note|tip|important|warning|caution)\}[ \t]*\n(.*?)(?:\n:::[ \t]*$|\z)/ms,
      text,
      fn _whole, class, body ->
        alert = Map.fetch!(@admonition_classes, class)

        quoted =
          body
          |> String.split("\n")
          |> Enum.map_join("\n", fn
            "" -> ">"
            line -> "> " <> line
          end)

        "> [!#{alert}]\n" <> quoted
      end
    )
  end

  defp preprocess_inline_roles(text) do
    text
    |> link_option_roles()
    |> strip_role_prefixes()
  end

  # {option}`name` always points at the tracker's own option page, regardless
  # of whether that option exists at the channel/revision being viewed.
  defp link_option_roles(text) do
    Regex.replace(~r/\{option\}`([^`]*)`/, text, fn _whole, name ->
      "[`#{name}`](#{~p"/options/#{name}"})"
    end)
  end

  # Remaining inline roles like `{manpage}`x`` carry a role prefix ahead of a
  # code span; render as plain code rather than resolving the role to a link.
  defp strip_role_prefixes(text) do
    Regex.replace(~r/\{[a-zA-Z][\w-]*\}(`[^`]*`)/, text, "\\1")
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign_new(:current_user, fn -> nil end)
     |> assign(:search_origin, nil)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    prefix = Map.get(params, "prefix", "")
    search = Map.get(params, "search", "")
    page = params |> Map.get("page", "1") |> String.to_integer() |> max(1)
    lens = socket.assigns.lens
    default_channel = if lens, do: lens.channel.name, else: ""
    default_rev = if lens && lens.revision, do: lens.revision.revision, else: ""
    channel = Map.get(params, "channel", default_channel)
    rev = Map.get(params, "rev", default_rev)

    # Options only exist per channel, so "All channels" has nothing honest to
    # show — every options page prompts for one instead of silently falling
    # back to a default. An explicit ?channel= override still wins.
    select_channel? =
      lens != nil and lens.all? and not Map.has_key?(params, "channel")

    channel_revision =
      if select_channel?, do: nil, else: resolve_channel_revision(channel, rev)

    search_origin = if search == "", do: nil, else: socket.assigns.search_origin

    {:noreply,
     socket
     |> assign(:page_title, if(prefix == "", do: "Options", else: prefix))
     |> assign(:search_origin, search_origin)
     |> assign(:prefix, prefix)
     |> assign(:parent_prefix, parent_prefix(prefix))
     |> assign(:channel, channel)
     |> assign(:rev, rev)
     |> assign(:channel_revision, channel_revision)
     |> assign(:select_channel?, select_channel?)
     |> assign(:highlight_lens?, select_channel?)
     |> assign(:channel_unavailable?, is_nil(channel_revision) and not select_channel?)
     |> assign(:search, search)
     |> assign(:offset, (page - 1) * 15)
     |> assign(:page_search, %PageSearch{
       action: show_path(prefix),
       value: search,
       event: "filter",
       hidden: %{},
       clear_to: search_origin && show_path(search_origin)
     })
     |> load_view()}
  end

  defp load_view(socket) do
    %{channel_revision: channel_revision, prefix: prefix, search: search} = socket.assigns

    {subgroups, leaf_options, files} =
      case channel_revision do
        nil -> {[], [], []}
        _cr when search != "" -> {[], [], []}
        cr when prefix == "" -> load_root_view(cr)
        cr -> load_prefix_view(cr, prefix)
      end

    leaf_options = drop_settable_set_duplicates(subgroups, leaf_options)

    # Per-option "Defined in" links (inside each leaf accordion) and the
    # recent-PRs-touching-the-subtree's-files list both ride option↔file spans.
    files_by_option = files_by_option(channel_revision, leaf_options)
    recent_prs = recent_prs_for_files(files)

    socket = load_matches(socket)

    nothing_here? =
      channel_revision != nil and subgroups == [] and leaf_options == [] and files == [] and
        socket.assigns.matches == []

    socket
    |> assign(:subgroups, subgroups)
    |> assign(:leaf_options, leaf_options)
    |> assign(:files, files)
    |> assign(:files_by_option, files_by_option)
    |> assign(:recent_prs, recent_prs)
    |> assign(:nothing_here?, nothing_here?)
  end

  # Per-leaf-option declaration files at the revision, as
  # `%{option_id => [file]}`, for the in-accordion "Defined in" links.
  defp files_by_option(_channel_revision, []), do: %{}

  defp files_by_option(channel_revision, leaf_options) do
    option_ids = Enum.map(leaf_options, & &1.option_id)

    channel_revision.channel_id
    |> Tracker.Nixpkgs.OptionFileSpan.files_for_options_at!(
      channel_revision.released_at,
      option_ids
    )
    |> Enum.group_by(& &1.option_id, & &1.file)
    |> Map.new(fn {option_id, files} -> {option_id, Enum.sort_by(files, & &1.path)} end)
  end

  defp files_for(files_by_option, option_id), do: Map.get(files_by_option, option_id, [])

  defp recent_prs_for_files([]), do: []

  defp recent_prs_for_files(files) do
    Tracker.Nixpkgs.Change.by_files!(Enum.map(files, & &1.id), 10)
  end

  # The fuzzy-ranked flat list of matches under the prefix, paginated.
  defp load_matches(socket) do
    %{channel_revision: channel_revision, prefix: prefix, search: search, offset: offset} =
      socket.assigns

    if channel_revision && search != "" do
      page =
        Tracker.Nixpkgs.OptionSpan.list_by_channel!(
          channel_revision.channel_id,
          channel_revision.released_at,
          search,
          prefix,
          page: [offset: offset, count: true]
        )

      socket
      |> assign(:matches, page.results)
      |> assign(:total_pages, ceil(page.count / 15))
      |> assign(:current_page, div(offset, 15) + 1)
      |> assign(:has_prev_page?, offset > 0)
      |> assign(:has_next_page?, page.more?)
    else
      socket
      |> assign(:matches, [])
      |> assign(:total_pages, 0)
      |> assign(:current_page, 1)
      |> assign(:has_prev_page?, false)
      |> assign(:has_next_page?, false)
    end
  end

  @impl true
  def handle_event("filter", params, socket) do
    search = Map.get(params, "search", "")
    %{search: current_search, prefix: prefix, search_origin: origin} = socket.assigns

    # A fresh search always scopes to the whole channel — searching from a
    # deep page would otherwise trap the query inside the current subtree.
    # The page it started from is remembered (in the socket only, never the
    # URL) so cancelling the search returns there; refining a search keeps
    # the original return point. Prefix-scoped search remains reachable by
    # URL, where clearing just stays put.
    {target_prefix, origin} =
      cond do
        search == "" -> {origin || prefix, nil}
        current_search == "" and prefix != "" -> {"", prefix}
        true -> {"", origin}
      end

    {:noreply,
     socket
     |> assign(:search_origin, origin)
     |> push_patch(to: options_path(target_prefix, search, 1))}
  end

  @impl true
  def handle_event("next-page", _params, socket) do
    %{prefix: prefix, search: search, current_page: current_page} = socket.assigns

    {:noreply, push_patch(socket, to: options_path(prefix, search, current_page + 1))}
  end

  @impl true
  def handle_event("prev-page", _params, socket) do
    %{prefix: prefix, search: search, current_page: current_page} = socket.assigns

    {:noreply, push_patch(socket, to: options_path(prefix, search, max(current_page - 1, 1)))}
  end

  defp options_path(prefix, search, page) do
    params =
      %{}
      |> then(fn p -> if search != "", do: Map.put(p, :search, search), else: p end)
      |> then(fn p -> if page > 1, do: Map.put(p, :page, page), else: p end)

    base = show_path(prefix)

    case URI.encode_query(params) do
      "" -> base
      qs -> "#{base}?#{qs}"
    end
  end

  # Both tree views are assembled from three narrow queries — subgroup counts
  # aggregated in the database, full detail for only the handful of leaf rows
  # the page renders, and the subtree's file set for Defined-in/recent PRs.
  # Hydrating every revision under a big prefix like `services` costs seconds.
  defp load_root_view(channel_revision) do
    subgroups =
      Tracker.Nixpkgs.OptionHistory.subgroup_counts(
        channel_revision.channel_id,
        channel_revision.released_at
      )

    leaf_revs =
      Tracker.Nixpkgs.OptionSpan.list_direct_by_prefix!(
        channel_revision.channel_id,
        channel_revision.released_at,
        ""
      )

    {subgroups, leaf_revs, []}
  end

  # An attrsOf-submodule option like services.bitcoind is both a real option
  # and a group with deeper children, so it would render twice: once as a child
  # card and once as a leaf detail row. Drop the duplicate leaf — its full
  # detail still renders as the self row on its own page. A subgroup never
  # equals the page prefix, so the self row is never dropped here.
  defp drop_settable_set_duplicates(subgroups, leaf_revs) do
    group_names = MapSet.new(subgroups, fn {name, _count} -> name end)

    Enum.reject(leaf_revs, fn rev -> MapSet.member?(group_names, rev.option.name) end)
  end

  defp load_prefix_view(channel_revision, prefix) do
    subgroups =
      Tracker.Nixpkgs.OptionHistory.subgroup_counts(
        channel_revision.channel_id,
        channel_revision.released_at,
        prefix
      )

    leaf_revs =
      Tracker.Nixpkgs.OptionSpan.list_direct_by_prefix!(
        channel_revision.channel_id,
        channel_revision.released_at,
        prefix
      )

    files =
      Tracker.Nixpkgs.File.files_for_prefix!(
        prefix,
        channel_revision.channel_id,
        channel_revision.released_at
      )

    {subgroups, leaf_revs, files}
  end

  defp parent_prefix(name) do
    case String.split(name, ".") do
      [_only] -> nil
      parts -> parts |> Enum.drop(-1) |> Enum.join(".")
    end
  end

  defp resolve_channel_revision(channel_name, "") do
    case Tracker.Nixpkgs.Channel.by_name(channel_name) do
      {:ok, channel} ->
        case Tracker.Nixpkgs.ChannelRevision.latest_by_channel(channel.id) do
          {:ok, cr} -> cr
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp resolve_channel_revision(channel_name, rev) do
    case Tracker.Nixpkgs.Channel.by_name(channel_name) do
      {:ok, channel} ->
        case Tracker.Nixpkgs.ChannelRevision.find_by_channel_hash(channel.id, rev) do
          {:ok, cr} -> cr
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @impl true
  def handle_info({:set_lens, channel_name, rev}, socket) do
    socket = TrackerWeb.LensHandlers.handle_lens_change(socket, channel_name, rev)

    {:noreply,
     push_patch(socket, to: options_path(socket.assigns.prefix, socket.assigns.search, 1))}
  end

  defp show_path(""), do: ~p"/options"
  defp show_path(prefix), do: ~p"/options/#{prefix}"
end

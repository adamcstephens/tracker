defmodule TrackerWeb.OptionLive.Show do
  use TrackerWeb, :live_view

  import TrackerWeb.CodeHighlight

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
                <dd :if={rev.description}>{rev.description}</dd>

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

                <dt :if={rev.files != []}>Defined in</dt>
                <dd :if={rev.files != []}>
                  <span :for={file <- rev.files}>
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

  defp option_packages(%Tracker.Nixpkgs.OptionRevision{option: %{packages: packages}}),
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

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_new(socket, :current_user, fn -> nil end)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    prefix = Map.get(params, "prefix", "")
    lens = socket.assigns.lens
    default_channel = if lens, do: lens.channel.name, else: ""
    default_rev = if lens && lens.revision, do: lens.revision.revision, else: ""
    channel = Map.get(params, "channel", default_channel)
    rev = Map.get(params, "rev", default_rev)

    # The root view has no channel of its own to fall back to: with the lens
    # on "All channels" (and no explicit ?channel=) it only prompts for one.
    select_channel? =
      prefix == "" and lens != nil and lens.all? and not Map.has_key?(params, "channel")

    channel_revision =
      if select_channel?, do: nil, else: resolve_channel_revision(channel, rev)

    {subgroups, leaf_options, files, leaf?} =
      case channel_revision do
        nil -> {[], [], [], false}
        cr when prefix == "" -> load_root_view(cr.id)
        cr -> load_prefix_view(cr.id, prefix)
      end

    recent_prs = recent_prs_for_files(files)

    nothing_here? =
      channel_revision != nil and subgroups == [] and leaf_options == [] and files == []

    {:noreply,
     socket
     |> assign(:page_title, if(prefix == "", do: "Options", else: prefix))
     |> assign(:prefix, prefix)
     |> assign(:parent_prefix, parent_prefix(prefix))
     |> assign(:channel, channel)
     |> assign(:rev, rev)
     |> assign(:channel_revision, channel_revision)
     |> assign(:select_channel?, select_channel?)
     |> assign(:highlight_lens?, select_channel?)
     |> assign(:channel_unavailable?, is_nil(channel_revision) and not select_channel?)
     |> assign(:subgroups, subgroups)
     |> assign(:leaf_options, leaf_options)
     |> assign(:files, files)
     |> assign(:recent_prs, recent_prs)
     |> assign(:leaf, leaf?)
     |> assign(:nothing_here?, nothing_here?)
     |> assign(:page_search, %PageSearch{
       mode: :passthrough,
       action: "/options",
       value: Map.get(params, "search", "")
     })}
  end

  defp recent_prs_for_files([]), do: []

  defp recent_prs_for_files(files) do
    Tracker.Nixpkgs.Change.by_files!(Enum.map(files, & &1.id), 10)
  end

  # The root tree is built from option names alone — loading every revision's
  # metadata and files for a whole channel just to count top-level groups
  # would be far too heavy. Only the few depth-1 leaves get full detail.
  defp load_root_view(channel_revision_id) do
    names =
      channel_revision_id
      |> Tracker.Nixpkgs.OptionRevision.list_names_by_channel_revision!()
      |> Enum.map(& &1.option_name)

    {leaf_names, deeper_names} = Enum.split_with(names, fn name -> depth(name) == 1 end)

    subgroups =
      deeper_names
      |> Enum.map(fn name -> name |> String.split(".") |> hd() end)
      |> Enum.frequencies()
      |> Enum.sort_by(fn {name, _} -> name end)

    leaf_revs =
      Enum.flat_map(leaf_names, fn name ->
        channel_revision_id
        |> Tracker.Nixpkgs.OptionRevision.list_by_channel_revision_and_prefix!(name)
        |> Enum.filter(fn rev -> rev.option.name == name end)
      end)

    {subgroups, leaf_revs, [], false}
  end

  defp load_prefix_view(channel_revision_id, prefix) do
    revisions =
      Tracker.Nixpkgs.OptionRevision.list_by_channel_revision_and_prefix!(
        channel_revision_id,
        prefix
      )

    prefix_depth = depth(prefix)

    {leaf_revs, deeper_revs} =
      Enum.split_with(revisions, fn rev ->
        depth(rev.option.name) <= prefix_depth + 1
      end)

    subgroups =
      deeper_revs
      |> Enum.map(fn rev ->
        rev.option.name
        |> String.split(".")
        |> Enum.take(prefix_depth + 1)
        |> Enum.join(".")
      end)
      |> Enum.frequencies()
      |> Enum.sort_by(fn {name, _} -> name end)

    files = unique_files(revisions)
    leaf? = Enum.any?(revisions, fn rev -> rev.option.name == prefix end)

    leaf_revs = Enum.sort_by(leaf_revs, & &1.option.name)

    {subgroups, leaf_revs, files, leaf?}
  end

  defp depth(name), do: name |> String.split(".") |> length()

  defp unique_files(revisions) do
    revisions
    |> Enum.flat_map(fn rev -> rev.files end)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.path)
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
    {:noreply, push_patch(socket, to: show_path(socket.assigns.prefix))}
  end

  defp show_path(""), do: ~p"/options"
  defp show_path(prefix), do: ~p"/options/#{prefix}"
end

defmodule TrackerWeb.OptionLive.Show do
  use TrackerWeb, :live_view

  import TrackerWeb.CodeHighlight

  alias TrackerWeb.PageSearch

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      {@prefix}
      <:subtitle>
        {if @leaf, do: "Option", else: "Options"}
        <span :if={@parent_prefix}>
          · parent: <.link navigate={~p"/options/#{@parent_prefix}"}>{@parent_prefix}</.link>
        </span>
        <span :if={@channel != ""}>
          · {@channel}
          <small :if={@channel_revision}>
            (<.revision_link revision={@channel_revision.revision} channel={@channel} />)
          </small>
        </span>
      </:subtitle>
    </.header>

    <p :if={@channel_unavailable?}>
      The {@channel} channel doesn't have options data.
    </p>

    <p :if={!@channel_unavailable? and @nothing_here?}>
      No options match this prefix in {@channel}.
    </p>

    <section :if={@subgroups != []}>
      <h2>Sub-groups</h2>
      <ul>
        <li :for={{group, count} <- @subgroups}>
          <.link navigate={~p"/options/#{group}"}>{group}</.link>
          <small>({count} options)</small>
        </li>
      </ul>
    </section>

    <section :if={@leaf_options != []}>
      <h2>Options ({length(@leaf_options)})</h2>
      <div id="options-list" phx-hook="AnchorExpand">
        <div :for={rev <- @leaf_options} id={"opt-row-#{rev.option.name}"}>
          <details id={"opt-#{rev.option.name}"} class="option-details">
            <summary>
              <strong>{rev.option.name}</strong>
              <span :if={rev.type} class="option-type-inline">{rev.type}</span>
              <a
                href={"#opt-#{rev.option.name}"}
                class="option-anchor"
                onclick="event.preventDefault(); history.replaceState(null, '', this.href); this.closest('details').open = !this.closest('details').open"
              >
                #
              </a>
            </summary>

            <dl class="option-body">
              <dt :if={rev.type}>Type</dt>
              <dd :if={rev.type}>
                {rev.type}
                <span :if={rev.read_only} class="option-read-only">(read-only)</span>
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
        </div>
      </div>
    </section>

    <section :if={@files != []}>
      <h2>Defined in</h2>
      <ul>
        <li :for={file <- @files}>
          <.declaration_link path={file.path} channel_revision={@channel_revision} />
        </li>
      </ul>
    </section>

    <section :if={@recent_prs != []}>
      <h2>Recent PRs</h2>
      <ul>
        <li :for={pr <- @recent_prs}>
          <.link navigate={~p"/changes/#{pr.number}"}>#{pr.number}</.link>
          {pr.title}
          <small :if={pr.state}>· {pr.state}</small>
        </li>
      </ul>
    </section>
    """
  end

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

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_new(socket, :current_user, fn -> nil end)}
  end

  @impl true
  def handle_params(%{"prefix" => prefix} = params, _url, socket) do
    lens = socket.assigns.lens
    default_channel = if lens, do: lens.channel.name, else: ""
    default_rev = if lens && lens.revision, do: lens.revision.revision, else: ""
    channel = Map.get(params, "channel", default_channel)
    rev = Map.get(params, "rev", default_rev)
    channel_revision = resolve_channel_revision(channel, rev)

    {subgroups, leaf_options, files, leaf?} =
      case channel_revision do
        nil -> {[], [], [], false}
        cr -> load_prefix_view(cr.id, prefix)
      end

    recent_prs = recent_prs_for_files(files)

    nothing_here? =
      channel_revision != nil and subgroups == [] and leaf_options == [] and files == []

    {:noreply,
     socket
     |> assign(:page_title, prefix)
     |> assign(:prefix, prefix)
     |> assign(:parent_prefix, parent_prefix(prefix))
     |> assign(:channel, channel)
     |> assign(:rev, rev)
     |> assign(:channel_revision, channel_revision)
     |> assign(:channel_unavailable?, is_nil(channel_revision))
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
    {:noreply, push_patch(socket, to: ~p"/options/#{socket.assigns.prefix}")}
  end
end

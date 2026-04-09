defmodule TrackerWeb.ModuleLive.Show do
  use TrackerWeb, :live_view

  import TrackerWeb.CodeHighlight

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      {@module.display_name}
      <:subtitle>
        Module
        <span :if={@parent_module}>
          · parent:
          <.link navigate={module_path(@parent_module.display_name, @channel, @rev)}>
            {@parent_module.display_name}
          </.link>
        </span>
        <span :if={@channel != ""}>
          · {@channel}
          <small :if={@channel_revision}>
            (<.revision_link revision={@channel_revision.revision} channel={@channel} />)
          </small>
        </span>
      </:subtitle>
    </.header>

    <section :if={@submodules != []}>
      <h2>Submodules ({length(@submodules)})</h2>
      <ul>
        <li :for={sub <- @submodules}>
          <.link navigate={module_path(sub.display_name, @channel, @rev)}>{sub.display_name}</.link>
          <small>({sub.option_count} options)</small>
        </li>
      </ul>
    </section>

    <section :if={@packages != []}>
      <h2>Packages</h2>
      <ul>
        <li :for={pkg <- @packages}>
          <.link navigate={~p"/packages/#{pkg.attribute}"}>{pkg.attribute}</.link>
          <small :if={pkg.description}>{pkg.description}</small>
        </li>
      </ul>
    </section>

    <p :if={@channel_unavailable?}>
      The {@channel} channel doesn't have options data.
    </p>

    <h2 :if={!@channel_unavailable?}>Options ({@option_count})</h2>

    <div :if={!@channel_unavailable?} id="options-list">
      <div :for={{id, rev} <- @streams.options} id={id}>
        <article id={"opt-#{option_name(rev)}"} style="margin-bottom: 1.5rem;">
          <header>
            <strong>{option_name(rev)}</strong>
            <span :if={rev.type} style="margin-left: 0.5rem;">
              <kbd>{rev.type}</kbd>
            </span>
            <kbd :if={rev.read_only} style="margin-left: 0.25rem;">
              read-only
            </kbd>
          </header>

          <p :if={rev.description}>{rev.description}</p>

          <dl>
            <dt :if={rev.default}>Default</dt>
            <dd :if={rev.default}><.code_block code={rev.default} /></dd>

            <dt :if={rev.example}>Example</dt>
            <dd :if={rev.example}><.code_block code={rev.example} /></dd>
          </dl>

          <div :if={option_packages(rev) != []}>
            <small>
              Packages:
              <span :for={pkg <- option_packages(rev)}>
                <.link navigate={~p"/packages/#{pkg.attribute}"}>{pkg.attribute}</.link>
              </span>
            </small>
          </div>
        </article>
      </div>
    </div>

    <nav
      :if={@total_pages > 1 and !@channel_unavailable?}
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

    <section :if={!@channel_unavailable?}>
      <h2>Declarations ({length(@module.module_declarations)})</h2>
      <ul>
        <li :for={md <- @module.module_declarations}>
          <.declaration_link path={md.path} channel_revision={@channel_revision} />
        </li>
      </ul>
    </section>
    """
  end

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

  defp option_name(%Tracker.Nixpkgs.OptionRevision{option: %{name: name}}), do: name

  defp option_packages(%Tracker.Nixpkgs.OptionRevision{option: %{packages: packages}}),
    do: packages

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_new(socket, :current_user, fn -> nil end)}
  end

  @impl true
  def handle_params(%{"name" => name} = params, _url, socket) do
    mod = Tracker.Nixpkgs.Module.get_by_name!(name)
    lens = socket.assigns.lens
    default_channel = if lens, do: lens.channel.name, else: ""
    default_rev = if lens && lens.revision, do: lens.revision.revision, else: ""
    channel = Map.get(params, "channel", default_channel)
    rev = Map.get(params, "rev", default_rev)
    page_num = params |> Map.get("page", "1") |> String.to_integer() |> max(1)
    offset = (page_num - 1) * 15

    packages = Tracker.Nixpkgs.Package.by_module!(mod.id)
    submodules = Tracker.Nixpkgs.Module.children!(mod.display_name)
    parent_module = find_parent_module(mod.display_name)

    channel_revision = resolve_channel_revision(channel, rev)

    {options_stream, option_count, has_more?} =
      if channel_revision do
        load_scoped_options(channel_revision.id, mod.id, offset)
      else
        {[], 0, false}
      end

    total_pages = ceil(option_count / 15)

    {:noreply,
     socket
     |> assign(:page_title, mod.display_name)
     |> assign(:module, mod)
     |> assign(:packages, packages)
     |> assign(:submodules, submodules)
     |> assign(:parent_module, parent_module)
     |> assign(:channel, channel)
     |> assign(:rev, rev)
     |> assign(:channel_revision, channel_revision)
     |> assign(:channel_unavailable?, is_nil(channel_revision))
     |> assign(:option_count, option_count)
     |> stream(:options, options_stream, reset: true)
     |> assign(:has_prev_page?, offset > 0)
     |> assign(:has_next_page?, has_more?)
     |> assign(:total_pages, total_pages)
     |> assign(:current_page, div(offset, 15) + 1)}
  end

  defp load_scoped_options(channel_revision_id, module_id, offset) do
    page =
      Tracker.Nixpkgs.OptionRevision.list_by_channel_revision_and_module!(
        channel_revision_id,
        module_id,
        page: [offset: offset, count: true]
      )

    {page.results, page.count, page.more?}
  end

  @impl true
  def handle_event("next-page", _params, socket) do
    {:noreply,
     push_patch(socket,
       to:
         show_path(
           socket.assigns.module.display_name,
           socket.assigns.channel,
           socket.assigns.rev,
           socket.assigns.current_page + 1
         )
     )}
  end

  @impl true
  def handle_event("prev-page", _params, socket) do
    {:noreply,
     push_patch(socket,
       to:
         show_path(
           socket.assigns.module.display_name,
           socket.assigns.channel,
           socket.assigns.rev,
           max(socket.assigns.current_page - 1, 1)
         )
     )}
  end

  defp module_path(name, channel, rev), do: show_path(name, channel, rev, 1)

  defp show_path(name, channel, rev, page) do
    params =
      %{}
      |> then(fn p -> if channel != "", do: Map.put(p, :channel, channel), else: p end)
      |> then(fn p -> if rev != "", do: Map.put(p, :rev, rev), else: p end)
      |> then(fn p -> if page > 1, do: Map.put(p, :page, page), else: p end)

    case URI.encode_query(params) do
      "" -> "/modules/#{name}"
      qs -> "/modules/#{name}?#{qs}"
    end
  end

  defp find_parent_module(display_name) do
    case String.split(display_name, ".") do
      [_single] ->
        nil

      parts ->
        parent_name = parts |> Enum.drop(-1) |> Enum.join(".")

        case Tracker.Nixpkgs.Module.get_by_name(parent_name) do
          {:ok, mod} -> mod
          _ -> nil
        end
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
     push_patch(socket,
       to:
         show_path(
           socket.assigns.module.display_name,
           channel_name,
           rev,
           1
         )
     )}
  end
end

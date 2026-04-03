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
        <span :if={@channel != ""}>
          · {@channel}
          <small :if={@channel_revision}>
            (<.revision_link revision={@channel_revision.revision} channel={@channel} />)
          </small>
        </span>
      </:subtitle>
    </.header>

    <.list>
      <:item title="Declarations">
        <ul style="list-style: none; padding: 0; margin: 0;">
          <li :for={md <- @module.module_declarations}>
            <code>{md.path}</code>
          </li>
        </ul>
      </:item>
    </.list>

    <section :if={@packages != []}>
      <h2>Packages</h2>
      <ul>
        <li :for={pkg <- @packages}>
          <.link navigate={~p"/packages/#{pkg.attribute}"}>{pkg.attribute}</.link>
          <small :if={pkg.description}>{pkg.description}</small>
        </li>
      </ul>
    </section>

    <h2>Options ({@option_count})</h2>

    <div :for={{id, item} <- @streams.options} id={id}>
      <% rev = resolve_rev(item, @revisions) %>
      <article id={"opt-#{option_name(item)}"} style="margin-bottom: 1.5rem;">
        <header>
          <strong>{option_name(item)}</strong>
          <span :if={rev} style="margin-left: 0.5rem;">
            <kbd>{rev.type}</kbd>
          </span>
          <kbd :if={rev && rev.read_only} style="margin-left: 0.25rem;">
            read-only
          </kbd>
        </header>

        <div :if={rev}>
          <p :if={rev.description}>{rev.description}</p>

          <dl>
            <dt :if={rev.default}>Default</dt>
            <dd :if={rev.default}><.code_block code={rev.default} /></dd>

            <dt :if={rev.example}>Example</dt>
            <dd :if={rev.example}><.code_block code={rev.example} /></dd>
          </dl>
        </div>

        <div :if={option_packages(item) != []}>
          <small>
            Packages:
            <span :for={pkg <- option_packages(item)}>
              <.link navigate={~p"/packages/#{pkg.attribute}"}>{pkg.attribute}</.link>
            </span>
          </small>
        </div>
      </article>
    </div>

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

    <.back navigate={back_path(@channel, @rev)}>Back to modules</.back>
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

  # When scoped, each stream item is an OptionRevision with nested option
  # When unscoped, each stream item is an Option with revisions looked up separately

  defp option_name(%Tracker.Nixpkgs.OptionRevision{option: %{name: name}}), do: name
  defp option_name(%Tracker.Nixpkgs.Option{name: name}), do: name

  defp resolve_rev(%Tracker.Nixpkgs.OptionRevision{} = rev, _revisions), do: rev
  defp resolve_rev(%Tracker.Nixpkgs.Option{id: id}, revisions), do: Map.get(revisions, id)

  defp option_packages(%Tracker.Nixpkgs.OptionRevision{option: %{packages: packages}}),
    do: packages

  defp option_packages(%Tracker.Nixpkgs.Option{packages: packages}), do: packages

  defp back_path("", _rev), do: ~p"/modules"

  defp back_path(channel, rev) do
    params =
      %{channel: channel}
      |> then(fn p -> if rev != "", do: Map.put(p, :rev, rev), else: p end)

    "/options?#{URI.encode_query(params)}"
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_new(socket, :current_user, fn -> nil end)}
  end

  @impl true
  def handle_params(%{"name" => name} = params, _url, socket) do
    mod = Tracker.Nixpkgs.Module.get_by_name!(name)
    channel = Map.get(params, "channel", "")
    rev = Map.get(params, "rev", "")
    page_num = params |> Map.get("page", "1") |> String.to_integer() |> max(1)
    offset = (page_num - 1) * 15

    packages = Tracker.Nixpkgs.Package.by_module!(mod.id)

    channel_revision =
      if channel != "" do
        resolve_channel_revision(channel, rev)
      end

    {options_stream, option_count, revisions, has_more?} =
      if channel_revision do
        load_scoped_options(channel_revision.id, mod.id, offset)
      else
        load_unscoped_options(mod.id, offset)
      end

    total_pages = ceil(option_count / 15)

    {:noreply,
     socket
     |> assign(:page_title, mod.display_name)
     |> assign(:module, mod)
     |> assign(:packages, packages)
     |> assign(:channel, channel)
     |> assign(:rev, rev)
     |> assign(:channel_revision, channel_revision)
     |> assign(:option_count, option_count)
     |> assign(:revisions, revisions)
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

    {page.results, page.count, %{}, page.more?}
  end

  defp load_unscoped_options(module_id, offset) do
    options_page =
      Tracker.Nixpkgs.Option.list_by_module!(module_id,
        page: [offset: offset, count: true]
      )

    option_ids = Enum.map(options_page.results, & &1.id)

    revisions =
      option_ids
      |> Tracker.Nixpkgs.OptionRevision.latest_by_option_ids!()
      |> Map.new(&{&1.option_id, &1})

    {options_page.results, options_page.count, revisions, options_page.more?}
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

  defp resolve_channel_revision(channel, "") do
    case Tracker.Nixpkgs.ChannelRevision.latest_by_channel(channel) do
      {:ok, cr} -> cr
      _ -> nil
    end
  end

  defp resolve_channel_revision(channel, rev) do
    case Tracker.Nixpkgs.ChannelRevision.find_by_channel_hash(channel, rev) do
      {:ok, cr} -> cr
      _ -> nil
    end
  end
end

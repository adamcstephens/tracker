defmodule TrackerWeb.OptionLive.Index do
  use TrackerWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Options
    </.header>

    <form phx-change="filter" phx-submit="filter" id="option-filter" phx-hook="UpdateURL">
      <fieldset role="group">
        <input
          type="search"
          name="search"
          value={@search}
          placeholder="Search options..."
          phx-debounce="300"
        />
        <select name="channel" aria-label="Filter by channel">
          <option value="">All channels</option>
          <option :for={ch <- @channels} value={ch.name} selected={ch.name == @channel}>
            {ch.name}
          </option>
        </select>
        <input
          :if={@channel != ""}
          type="text"
          name="rev"
          value={@rev}
          placeholder="Revision hash..."
          phx-debounce="300"
        />
      </fieldset>
    </form>

    <p :if={@channel_unavailable?}>
      The {@channel} channel doesn't have options data.
    </p>

    <.table id="options" rows={@streams.options}>
      <:col :let={{_id, row}} label="Option">
        <.option_link option={option_record(row)} channel={@channel} rev={@rev} />
      </:col>
      <:col :let={{_id, row}} label="Module">
        <.module_link module={option_module(row)} channel={@channel} rev={@rev} />
      </:col>
    </.table>

    <nav style="display: flex; align-items: center; justify-content: center; gap: 0.5rem; margin-top: 1rem;">
      <.button
        class="outline secondary"
        style="padding: 0.25rem 0.75rem; font-size: 0.875rem;"
        phx-click="prev-page"
        disabled={!@has_prev_page?}
      >
        &larr;
      </.button>
      <small :if={@total_pages > 0}>
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

  attr :option, :any, required: true
  attr :channel, :string, required: true
  attr :rev, :string, required: true

  defp option_link(%{option: %{module: nil}} = assigns), do: ~H"<span>{@option.name}</span>"

  defp option_link(assigns) do
    ~H"""
    <.link navigate={module_path(@option.module.display_name, @channel, @rev, @option.name)}>
      {@option.name}
    </.link>
    """
  end

  attr :module, :any, required: true
  attr :channel, :string, required: true
  attr :rev, :string, required: true

  defp module_link(%{module: nil} = assigns), do: ~H""

  defp module_link(assigns) do
    ~H"""
    <.link navigate={module_path(@module.display_name, @channel, @rev)}>
      {@module.display_name}
    </.link>
    """
  end

  defp option_record(%Tracker.Nixpkgs.OptionRevision{option: option}), do: option
  defp option_record(%Tracker.Nixpkgs.Option{} = option), do: option

  defp option_module(%Tracker.Nixpkgs.OptionRevision{option: %{module: mod}}), do: mod
  defp option_module(%Tracker.Nixpkgs.Option{module: mod}), do: mod

  defp module_path(name, channel, rev, anchor \\ nil) do
    params =
      %{}
      |> then(fn p -> if channel != "", do: Map.put(p, :channel, channel), else: p end)
      |> then(fn p -> if rev != "", do: Map.put(p, :rev, rev), else: p end)

    path =
      case URI.encode_query(params) do
        "" -> "/modules/#{name}"
        qs -> "/modules/#{name}?#{qs}"
      end

    if anchor, do: "#{path}#opt-#{anchor}", else: path
  end

  @impl true
  def mount(_params, _session, socket) do
    channels = Tracker.Nixpkgs.Channel.nixos_channels!()

    {:ok,
     socket
     |> assign_new(:current_user, fn -> nil end)
     |> assign(:channels, channels)
     |> assign(:channel_unavailable?, false)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    search = Map.get(params, "search", "")
    channel = Map.get(params, "channel", "")
    rev = Map.get(params, "rev", "")
    page = params |> Map.get("page", "1") |> String.to_integer() |> max(1)
    offset = (page - 1) * 15

    socket = assign(socket, :page_title, "Options")

    socket =
      if socket.assigns[:search] == search and
           socket.assigns[:channel] == channel and
           socket.assigns[:rev] == rev and
           socket.assigns[:offset] == offset do
        socket
      else
        socket
        |> assign(:search, search)
        |> assign(:channel, channel)
        |> assign(:rev, rev)
        |> assign(:offset, offset)
        |> load_data()
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter", params, socket) do
    search = Map.get(params, "search", "")
    channel = Map.get(params, "channel", "")
    rev = if channel == "", do: "", else: Map.get(params, "rev", "")

    socket =
      socket
      |> assign(:search, search)
      |> assign(:channel, channel)
      |> assign(:rev, rev)
      |> assign(:offset, 0)
      |> load_data()
      |> push_event("update-url", %{path: options_path(search, channel, rev, 1)})

    {:noreply, socket}
  end

  @impl true
  def handle_event("next-page", _params, socket) do
    {:noreply,
     push_patch(socket,
       to:
         options_path(
           socket.assigns.search,
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
         options_path(
           socket.assigns.search,
           socket.assigns.channel,
           socket.assigns.rev,
           max(socket.assigns.current_page - 1, 1)
         )
     )}
  end

  defp options_path(search, channel, rev, page) do
    params =
      %{}
      |> then(fn p -> if search != "", do: Map.put(p, :search, search), else: p end)
      |> then(fn p -> if channel != "", do: Map.put(p, :channel, channel), else: p end)
      |> then(fn p -> if rev != "", do: Map.put(p, :rev, rev), else: p end)
      |> then(fn p -> if page > 1, do: Map.put(p, :page, page), else: p end)

    case URI.encode_query(params) do
      "" -> "/options"
      qs -> "/options?#{qs}"
    end
  end

  defp load_data(socket) do
    if socket.assigns.channel != "" do
      load_scoped(socket)
    else
      load_options(socket)
    end
  end

  defp load_options(socket) do
    page =
      Tracker.Nixpkgs.Option.list!(socket.assigns.search,
        page: [offset: socket.assigns.offset, count: true]
      )

    total_pages = ceil(page.count / 15)
    current_page = div(socket.assigns.offset, 15) + 1

    socket
    |> assign(:channel_unavailable?, false)
    |> stream(:options, page.results, reset: true)
    |> assign(:has_prev_page?, socket.assigns.offset > 0)
    |> assign(:has_next_page?, page.more?)
    |> assign(:total_pages, total_pages)
    |> assign(:current_page, current_page)
  end

  defp load_scoped(socket) do
    channel_revision =
      resolve_channel_revision(socket.assigns.channel, socket.assigns.rev)

    if channel_revision do
      page =
        Tracker.Nixpkgs.OptionRevision.list_by_channel_revision!(
          channel_revision.id,
          socket.assigns.search,
          page: [offset: socket.assigns.offset, count: true]
        )

      total_pages = ceil(page.count / 15)
      current_page = div(socket.assigns.offset, 15) + 1

      socket
      |> assign(:channel_unavailable?, false)
      |> stream(:options, page.results, reset: true)
      |> assign(:has_prev_page?, socket.assigns.offset > 0)
      |> assign(:has_next_page?, page.more?)
      |> assign(:total_pages, total_pages)
      |> assign(:current_page, current_page)
    else
      socket
      |> assign(:channel_unavailable?, true)
      |> stream(:options, [], reset: true)
      |> assign(:has_prev_page?, false)
      |> assign(:has_next_page?, false)
      |> assign(:total_pages, 0)
      |> assign(:current_page, 1)
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
       to: options_path(socket.assigns.search, channel_name, rev, 1)
     )}
  end
end

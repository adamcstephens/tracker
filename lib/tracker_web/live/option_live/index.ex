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
          <option :for={ch <- @channels} value={ch} selected={ch == @channel}>
            {ch}
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

    <.table
      id="options"
      rows={@streams.options}
    >
      <:col :let={{_id, row}} label="Option">
        {option_name(row)}
      </:col>
      <:col :let={{_id, row}} :if={!@scoped?} label="Module">
        <.link :if={row.module} navigate={~p"/modules/#{row.module.display_name}"}>
          {row.module.display_name}
        </.link>
      </:col>
      <:col :let={{_id, row}} :if={@scoped?} label="Type">
        {row.type}
      </:col>
      <:col :let={{_id, row}} :if={@scoped?} label="Description">
        <span style="display: block; max-width: 40ch; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
          {row.description}
        </span>
      </:col>
      <:col :let={{_id, row}} :if={@scoped?} label="Default">
        {row.default}
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

  defp option_name(%Tracker.Nixpkgs.OptionRevision{option: %{name: name}}), do: name
  defp option_name(%Tracker.Nixpkgs.Option{name: name}), do: name
  defp option_name(%{name: name}), do: name

  @impl true
  def mount(_params, _session, socket) do
    channels =
      Tracker.Nixpkgs.ChannelRevision.distinct_channels!()
      |> Enum.map(& &1.channel)

    {:ok,
     socket
     |> assign_new(:current_user, fn -> nil end)
     |> assign(:channels, channels)}
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
    channel = socket.assigns.channel
    rev = socket.assigns.rev

    if channel != "" do
      load_scoped(socket, channel, rev)
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
    |> stream(:options, page.results, reset: true)
    |> assign(:scoped?, false)
    |> assign(:has_prev_page?, socket.assigns.offset > 0)
    |> assign(:has_next_page?, page.more?)
    |> assign(:total_pages, total_pages)
    |> assign(:current_page, current_page)
  end

  defp load_scoped(socket, channel, rev) do
    channel_revision = resolve_channel_revision(channel, rev)

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
      |> stream(:options, page.results, reset: true)
      |> assign(:scoped?, true)
      |> assign(:has_prev_page?, socket.assigns.offset > 0)
      |> assign(:has_next_page?, page.more?)
      |> assign(:total_pages, total_pages)
      |> assign(:current_page, current_page)
    else
      socket
      |> stream(:options, [], reset: true)
      |> assign(:scoped?, true)
      |> assign(:has_prev_page?, false)
      |> assign(:has_next_page?, false)
      |> assign(:total_pages, 0)
      |> assign(:current_page, 1)
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

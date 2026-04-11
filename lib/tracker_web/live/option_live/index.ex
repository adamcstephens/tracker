defmodule TrackerWeb.OptionLive.Index do
  use TrackerWeb, :live_view

  alias TrackerWeb.DataTable

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Options
    </.header>

    <form phx-change="filter" phx-submit="filter" id="option-filter" phx-hook="UpdateURL">
      <input
        type="search"
        name="search"
        value={@search}
        placeholder="Search options..."
        phx-debounce="300"
      />
    </form>

    <p :if={@channel_unavailable?}>
      The {@lens.channel.name} channel doesn't have options data.
    </p>

    <.table id="options" rows={@streams.options}>
      <:col :let={{_id, row}} label="Option">
        <.option_link option={option_record(row)} />
      </:col>
      <:col :let={{_id, row}} label="Module">
        <.module_link module={option_module(row)} />
      </:col>
    </.table>

    <DataTable.pagination
      total_pages={@total_pages}
      current_page={@current_page}
      has_prev_page?={@has_prev_page?}
      has_next_page?={@has_next_page?}
    />
    """
  end

  attr :option, :any, required: true

  defp option_link(%{option: %{module: nil}} = assigns), do: ~H"<span>{@option.name}</span>"

  defp option_link(assigns) do
    ~H"""
    <.link navigate={module_path(@option.module.display_name, @option.name)}>
      {@option.name}
    </.link>
    """
  end

  attr :module, :any, required: true

  defp module_link(%{module: nil} = assigns), do: ~H""

  defp module_link(assigns) do
    ~H"""
    <.link navigate={module_path(@module.display_name)}>
      {@module.display_name}
    </.link>
    """
  end

  defp option_record(%Tracker.Nixpkgs.OptionRevision{option: option}), do: option
  defp option_record(%Tracker.Nixpkgs.Option{} = option), do: option

  defp option_module(%Tracker.Nixpkgs.OptionRevision{option: %{module: mod}}), do: mod
  defp option_module(%Tracker.Nixpkgs.Option{module: mod}), do: mod

  defp module_path(name, anchor \\ nil) do
    path = "/modules/#{name}"
    if anchor, do: "#{path}#opt-#{anchor}", else: path
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign_new(:current_user, fn -> nil end)
     |> assign(:channel_unavailable?, false)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    search = Map.get(params, "search", "")
    page = params |> Map.get("page", "1") |> String.to_integer() |> max(1)
    offset = (page - 1) * 15

    socket = assign(socket, :page_title, "Options")

    socket =
      if socket.assigns[:search] == search and
           socket.assigns[:offset] == offset do
        socket
      else
        socket
        |> assign(:search, search)
        |> assign(:offset, offset)
        |> load_data()
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter", params, socket) do
    search = Map.get(params, "search", "")

    socket =
      socket
      |> assign(:search, search)
      |> assign(:offset, 0)
      |> load_data()
      |> push_event("update-url", %{path: options_path(search, 1)})

    {:noreply, socket}
  end

  @impl true
  def handle_event("next-page", _params, socket) do
    {:noreply,
     push_patch(socket,
       to: options_path(socket.assigns.search, socket.assigns.current_page + 1)
     )}
  end

  @impl true
  def handle_event("prev-page", _params, socket) do
    {:noreply,
     push_patch(socket,
       to: options_path(socket.assigns.search, max(socket.assigns.current_page - 1, 1))
     )}
  end

  defp options_path(search, page) do
    params =
      %{}
      |> then(fn p -> if search != "", do: Map.put(p, :search, search), else: p end)
      |> then(fn p -> if page > 1, do: Map.put(p, :page, page), else: p end)

    case URI.encode_query(params) do
      "" -> "/options"
      qs -> "/options?#{qs}"
    end
  end

  defp load_data(socket) do
    lens = socket.assigns.lens

    channel_revision =
      if lens && lens.revision do
        lens.revision
      else
        resolve_latest_revision(lens)
      end

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

  defp resolve_latest_revision(nil), do: nil

  defp resolve_latest_revision(lens) do
    case Tracker.Nixpkgs.ChannelRevision.latest_by_channel(lens.channel.id) do
      {:ok, cr} -> cr
      _ -> nil
    end
  end

  @impl true
  def handle_info({:set_lens, channel_name, rev}, socket) do
    socket = TrackerWeb.LensHandlers.handle_lens_change(socket, channel_name, rev)
    {:noreply, load_data(socket)}
  end
end

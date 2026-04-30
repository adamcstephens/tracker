defmodule TrackerWeb.ChangeLive.Show do
  use TrackerWeb, :live_view

  alias TrackerWeb.DataTable
  alias TrackerWeb.TableParams

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      <a href={@change.url} target="_blank" rel="noopener noreferrer">
        #{@change.number}
      </a>
      {@change.title}
    </.header>

    <.list>
      <:item title="State">
        <mark :if={@change.state == :merged}>merged</mark>
        <span :if={@change.state == :open}>open</span>
        <span :if={@change.state == :closed}>closed</span>
      </:item>
      <:item title="Author">
        {author_display(@change, @author_maintainer)}
      </:item>
      <:item :if={@merger_maintainer} title="Merged by">
        <.link navigate={~p"/maintainers/#{@merger_maintainer.github}"}>
          {@merger_maintainer.github}
        </.link>
      </:item>
      <:item title="Base branch">{@change.base_ref}</:item>
      <:item :if={@change.merged_at} title="Merged at">
        {format_datetime(@change.merged_at)}
      </:item>
      <:item :if={@change.gh_created_at} title="Created at">
        {format_datetime(@change.gh_created_at)}
      </:item>
      <:item :if={@change.merge_commit_sha} title="Merge commit">
        <a
          href={"https://github.com/NixOS/nixpkgs/commit/#{@change.merge_commit_sha}"}
          target="_blank"
          rel="noopener noreferrer"
        >
          {String.slice(@change.merge_commit_sha, 0, 12)}
        </a>
      </:item>
    </.list>

    <div :if={@change.labels && @change.labels != []} style="margin-top: 1rem;">
      <strong>Labels</strong>
      <div style="display: flex; flex-wrap: wrap; gap: 0.25rem; margin-top: 0.25rem;">
        <kbd :for={label <- @change.labels} style="font-size: 0.75rem;">
          {label}
        </kbd>
      </div>
    </div>

    <section>
      <h2>Affected Packages ({@package_count})</h2>

      <form
        :if={@package_count > 15}
        phx-change="search-packages"
        phx-submit="search-packages"
        id="package-search"
        phx-hook="UpdateURL"
      >
        <input
          type="search"
          name="search"
          value={@table_params.search}
          placeholder="Filter packages..."
          phx-debounce="300"
        />
      </form>

      <.table id="affected-packages" rows={@streams.packages}>
        <:col :let={{_id, pkg}} label="Package">
          <.link navigate={~p"/packages/#{pkg.attribute}"}>{pkg.attribute}</.link>
        </:col>
        <:col :let={{_id, pkg}} label="Description">
          <span style="display: block; max-width: 40ch; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
            {pkg.description}
          </span>
        </:col>
      </.table>

      <p :if={@package_count == 0}>No affected packages found.</p>

      <DataTable.pagination
        total_pages={@pkg_total_pages}
        current_page={@pkg_current_page}
        has_prev_page?={@pkg_has_prev?}
        has_next_page?={@pkg_has_next?}
      />
    </section>

    <section :if={@affected_prefixes != []}>
      <h2>Affected options</h2>
      <ul>
        <li :for={{prefix, count} <- @affected_prefixes}>
          <.link navigate={~p"/options/#{prefix}"}>{prefix}</.link>
          <small>({count} options)</small>
        </li>
      </ul>
    </section>
    """
  end

  defp format_datetime(nil), do: "-"
  defp format_datetime(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  defp author_display(change, nil), do: change.author || "Unknown"

  defp author_display(_change, maintainer) do
    assigns = %{maintainer: maintainer}

    ~H"""
    <.link navigate={~p"/maintainers/#{@maintainer.github}"}>
      {@maintainer.github}
    </.link>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_new(socket, :current_user, fn -> nil end)}
  end

  @impl true
  def handle_params(%{"number" => number_str} = params, _url, socket) do
    number = String.to_integer(number_str)
    change = Tracker.Nixpkgs.Change.get_by_number!(number)

    author_maintainer = find_maintainer(change.author_github_id)
    merger_maintainer = find_maintainer(change.merged_by_github_id)

    tp = TableParams.from_params(params)

    {:noreply,
     socket
     |> assign(:page_title, "##{change.number} #{change.title}")
     |> assign(:change, change)
     |> assign(:author_maintainer, author_maintainer)
     |> assign(:merger_maintainer, merger_maintainer)
     |> assign(:table_params, tp)
     |> load_packages(change.id)
     |> load_affected_prefixes(change.id, socket.assigns.lens)}
  end

  defp load_affected_prefixes(socket, change_id, lens) do
    prefixes =
      case channel_revision_for_lens(lens) do
        nil ->
          []

        cr ->
          change_id
          |> Tracker.Nixpkgs.OptionRevision.list_by_change_and_channel_revision!(cr.id)
          |> Enum.map(&fold_to_prefix(&1.option.name))
          |> Enum.frequencies()
          |> Enum.sort_by(fn {prefix, _} -> prefix end)
      end

    assign(socket, :affected_prefixes, prefixes)
  end

  defp channel_revision_for_lens(nil), do: nil
  defp channel_revision_for_lens(%{revision: %{} = cr}), do: cr

  defp channel_revision_for_lens(%{channel: %{id: channel_id}}) do
    case Tracker.Nixpkgs.ChannelRevision.latest_by_channel(channel_id) do
      {:ok, cr} -> cr
      _ -> nil
    end
  end

  defp fold_to_prefix(name) do
    case String.split(name, ".") do
      [single] -> single
      [a, b | _] -> a <> "." <> b
    end
  end

  @impl true
  def handle_event("search-packages", %{"search" => search}, socket) do
    tp = %{socket.assigns.table_params | search: search, page: 1, offset: 0}

    socket =
      socket
      |> assign(:table_params, tp)
      |> load_packages(socket.assigns.change.id)
      |> push_event("update-url", %{
        path: TableParams.to_path(tp, "/changes/#{socket.assigns.change.number}")
      })

    {:noreply, socket}
  end

  @impl true
  def handle_event("next-page", _params, socket) do
    tp = socket.assigns.table_params

    {:noreply,
     push_patch(socket,
       to:
         TableParams.to_path(
           %{tp | page: tp.page + 1},
           "/changes/#{socket.assigns.change.number}"
         )
     )}
  end

  @impl true
  def handle_event("prev-page", _params, socket) do
    tp = socket.assigns.table_params

    {:noreply,
     push_patch(socket,
       to:
         TableParams.to_path(
           %{tp | page: max(tp.page - 1, 1)},
           "/changes/#{socket.assigns.change.number}"
         )
     )}
  end

  defp load_packages(socket, change_id) do
    tp = socket.assigns.table_params
    package_count = socket.assigns.change.package_count || 0

    page =
      Tracker.Nixpkgs.Package.by_change!(change_id, tp.search, page: [offset: tp.offset])

    total_pages = if package_count > 0, do: ceil(package_count / tp.page_size), else: 0

    socket
    |> stream(:packages, page.results, reset: true)
    |> assign(:package_count, package_count)
    |> assign(:pkg_has_prev?, tp.offset > 0)
    |> assign(:pkg_has_next?, page.more?)
    |> assign(:pkg_total_pages, total_pages)
    |> assign(:pkg_current_page, tp.page)
  end

  defp find_maintainer(nil), do: nil

  defp find_maintainer(github_id) do
    case Tracker.Nixpkgs.Maintainer.get_by_github_id(github_id) do
      {:ok, maintainer} -> maintainer
      _ -> nil
    end
  end

  @impl true
  def handle_info({:set_lens, channel_name, rev}, socket) do
    {:noreply, TrackerWeb.LensHandlers.handle_lens_change(socket, channel_name, rev)}
  end
end

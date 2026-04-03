defmodule TrackerWeb.ChangeLive.Show do
  use TrackerWeb, :live_view

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
          value={@pkg_search}
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

      <nav
        :if={@pkg_total_pages > 1}
        style="display: flex; align-items: center; justify-content: center; gap: 0.5rem; margin-top: 1rem;"
      >
        <.button
          class="outline secondary"
          style="padding: 0.25rem 0.75rem; font-size: 0.875rem;"
          phx-click="prev-page"
          disabled={!@pkg_has_prev?}
        >
          &larr;
        </.button>
        <small>
          Page {@pkg_current_page} of {@pkg_total_pages}
        </small>
        <.button
          class="outline secondary"
          style="padding: 0.25rem 0.75rem; font-size: 0.875rem;"
          phx-click="next-page"
          disabled={!@pkg_has_next?}
        >
          &rarr;
        </.button>
      </nav>
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

    pkg_search = Map.get(params, "search", "")
    page = params |> Map.get("page", "1") |> String.to_integer() |> max(1)
    offset = (page - 1) * 15

    {:noreply,
     socket
     |> assign(:page_title, "##{change.number} #{change.title}")
     |> assign(:change, change)
     |> assign(:author_maintainer, author_maintainer)
     |> assign(:merger_maintainer, merger_maintainer)
     |> assign(:pkg_search, pkg_search)
     |> assign(:pkg_offset, offset)
     |> load_packages(change.id, pkg_search, offset)}
  end

  @impl true
  def handle_event("search-packages", %{"search" => search}, socket) do
    socket =
      socket
      |> assign(:pkg_search, search)
      |> assign(:pkg_offset, 0)
      |> load_packages(socket.assigns.change.id, search, 0)
      |> push_event("update-url", %{path: show_path(socket.assigns.change.number, search, 1)})

    {:noreply, socket}
  end

  @impl true
  def handle_event("next-page", _params, socket) do
    {:noreply,
     push_patch(socket,
       to:
         show_path(
           socket.assigns.change.number,
           socket.assigns.pkg_search,
           socket.assigns.pkg_current_page + 1
         )
     )}
  end

  @impl true
  def handle_event("prev-page", _params, socket) do
    {:noreply,
     push_patch(socket,
       to:
         show_path(
           socket.assigns.change.number,
           socket.assigns.pkg_search,
           max(socket.assigns.pkg_current_page - 1, 1)
         )
     )}
  end

  defp load_packages(socket, change_id, search, offset) do
    package_count = socket.assigns.change.package_count || 0

    page =
      Tracker.Nixpkgs.Package.by_change!(change_id, search, page: [offset: offset])

    total_pages = if package_count > 0, do: ceil(package_count / 15), else: 0
    current_page = div(offset, 15) + 1

    socket
    |> stream(:packages, page.results, reset: true)
    |> assign(:package_count, package_count)
    |> assign(:pkg_has_prev?, offset > 0)
    |> assign(:pkg_has_next?, page.more?)
    |> assign(:pkg_total_pages, total_pages)
    |> assign(:pkg_current_page, current_page)
  end

  defp show_path(number, search, page) do
    params =
      %{}
      |> then(fn p -> if search != "", do: Map.put(p, :search, search), else: p end)
      |> then(fn p -> if page > 1, do: Map.put(p, :page, page), else: p end)

    case URI.encode_query(params) do
      "" -> "/changes/#{number}"
      qs -> "/changes/#{number}?#{qs}"
    end
  end

  defp find_maintainer(nil), do: nil

  defp find_maintainer(github_id) do
    case Tracker.Nixpkgs.Maintainer.get_by_github_id(github_id) do
      {:ok, maintainer} -> maintainer
      _ -> nil
    end
  end
end

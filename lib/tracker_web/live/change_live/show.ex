defmodule TrackerWeb.ChangeLive.Show do
  @moduledoc """
  Redesigned Change Show page.

  Goals:
    * Lead with propagation status (the #1 question: "has it landed in
      my channel yet?") for merged PRs.
    * Cleaner, scannable metadata grid.
    * Compact label chips and a fast searchable packages table.
    * No new JS dependencies — this template only uses LiveView's
      built-in events; the search form falls back to a regular GET.

  Compared to the previous version this:
    * Drops the affected option prefixes section.
    * Drops the inline "timeline" strip below the DAG.
    * Hides propagation entirely until the change is merged.
    * Replaces the dl + <mark> state with a status pill.
    * Renders the DAG without column headers (the labels were
      cluttering and not helping comprehension).
  """

  use TrackerWeb, :live_view

  alias TrackerWeb.DataTable
  alias TrackerWeb.PageSearch
  alias TrackerWeb.PropagationDag
  alias TrackerWeb.TableParams
  alias Tracker.Nixpkgs.Propagation

  @impl true
  def render(assigns) do
    ~H"""
    <div class="change-show">
      <header class="change-head">
        <div class="change-head-row">
          <span class={"pill pill-#{@change.state}"}>
            <span class="dot" aria-hidden="true"></span>
            {@change.state}
          </span>
          <a href={@change.url} target="_blank" rel="noopener noreferrer" class="change-prnum mono">
            #{@change.number}
          </a>
          <span class="muted">→ <code>{@change.base_ref}</code></span>
        </div>
        <h1>{@change.title}</h1>
      </header>

      <section
        :if={@change.state == :merged and @lifecycle_dag.nodes != []}
        class="change-card change-card-prop"
      >
        <div class="change-card-head">
          <small class="muted">
            <strong>{@landed_count}</strong> of {@total_branches} channels reached
          </small>
        </div>
        <PropagationDag.dag dag={@lifecycle_dag} />
      </section>

      <dl class="change-meta">
        <div>
          <dt>Link</dt>
          <dd>
            <a href={@change.url} target="_blank" rel="noopener noreferrer">
              #{@change.number}
            </a>
          </dd>
        </div>
        <div>
          <dt>Author</dt>
          <dd>{author_display(@change, @author_maintainer)}</dd>
        </div>
        <div :if={@merger_maintainer}>
          <dt>Merged by</dt>
          <dd>
            <.link navigate={~p"/maintainers/#{@merger_maintainer.github}"}>
              {@merger_maintainer.github}
            </.link>
          </dd>
        </div>
        <div :if={@change.gh_created_at}>
          <dt>Created</dt>
          <dd>{format_datetime(@change.gh_created_at)} <small>UTC</small></dd>
        </div>
        <div :if={@change.merged_at}>
          <dt>Merged</dt>
          <dd>{format_datetime(@change.merged_at)} <small>UTC</small></dd>
        </div>
        <div>
          <dt>Base branch</dt>
          <dd><code>{@change.base_ref}</code></dd>
        </div>
        <div :if={@change.merge_commit_sha}>
          <dt>Merge commit</dt>
          <dd>
            <a
              href={"https://github.com/NixOS/nixpkgs/commit/#{@change.merge_commit_sha}"}
              target="_blank"
              rel="noopener noreferrer"
              class="mono"
            >
              {String.slice(@change.merge_commit_sha, 0, 12)}
            </a>
          </dd>
        </div>
      </dl>

      <section class="change-section">
        <div class="change-section-head">
          <h2>
            Affected packages <small class="muted">({@package_count})</small>
          </h2>

          <form
            :if={@package_count > 15 && @change.processing_status == :processed}
            phx-change="search-packages"
            phx-submit="search-packages"
            id="package-search"
            phx-hook="UpdateURL"
            method="get"
            action={~p"/changes/#{@change.number}"}
          >
            <input
              type="search"
              name="search"
              value={@table_params.search}
              placeholder="Filter packages…"
              phx-debounce="300"
            />
          </form>
        </div>

        <p :if={@change.processing_status != :processed}>
          {processing_status_explanation(@change.processing_status, @change)}
        </p>

        <%= if @change.processing_status == :processed and @package_count > 0 do %>
          <.table id="affected-packages" rows={@streams.packages}>
            <:col :let={{_id, pkg}} label="Package">
              <.link navigate={~p"/packages/#{pkg.attribute}"} class="mono">
                {pkg.attribute}
              </.link>
            </:col>
            <:col :let={{_id, pkg}} label="Description">
              <span class="change-desc">{pkg.description}</span>
            </:col>
          </.table>

          <DataTable.pagination
            total_pages={@pkg_total_pages}
            current_page={@pkg_current_page}
            has_prev_page?={@pkg_has_prev?}
            has_next_page?={@pkg_has_next?}
          />
        <% end %>

        <p :if={@change.processing_status == :processed and @package_count == 0}>
          No affected packages found.
        </p>
      </section>

      <div :if={@change.labels && @change.labels != []} class="change-labels">
        <span :for={label <- @change.labels} class="label-chip">{label}</span>
      </div>
    </div>
    """
  end

  defp format_datetime(nil), do: "—"
  defp format_datetime(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  defp processing_status_explanation(:pending, _),
    do: "This change hasn't been processed yet."

  defp processing_status_explanation(:base_ref_skipped, change),
    do:
      "Targets #{change.base_ref}. Per-package relations are skipped when targeting mass-rebuild branches"

  defp processing_status_explanation(:too_large, change),
    do:
      "The attrdiff touched #{change.package_count} attributes, over the per-change link cap. " <>
        "Per-package links were not written."

  defp processing_status_explanation(:artifact_expired, _),
    do: "GitHub's nixpkgs-review artifact has expired, so we can't compute affected packages."

  defp processing_status_explanation(:no_workflow_run, _),
    do: "No nixpkgs-review workflow run was found for this change."

  defp processing_status_explanation(:no_comparison_artifact, _),
    do: "No comparison artifact was found in the workflow run."

  defp processing_status_explanation(:failed, _),
    do: "Processing failed for this change."

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

    change =
      number
      |> Tracker.Nixpkgs.Change.get_by_number!()
      |> Ash.load!(:change_branches)

    author_maintainer = find_maintainer(change.author_github_id)
    merger_maintainer = find_maintainer(change.merged_by_github_id)

    tp = TableParams.from_params(params)

    present_branches = Enum.map(change.change_branches, & &1.branch_name)
    lifecycle_dag = Propagation.lifecycle(change.base_ref, present_branches)

    landed_count = Enum.count(lifecycle_dag.nodes, & &1.present)
    total_branches = length(lifecycle_dag.nodes)

    {:noreply,
     socket
     |> assign(:page_title, "##{change.number} #{change.title}")
     |> assign(:change, change)
     |> assign(:author_maintainer, author_maintainer)
     |> assign(:merger_maintainer, merger_maintainer)
     |> assign(:lifecycle_dag, lifecycle_dag)
     |> assign(:landed_count, landed_count)
     |> assign(:total_branches, total_branches)
     |> assign(:table_params, tp)
     |> assign(:page_search, %PageSearch{
       mode: :passthrough,
       action: "/changes",
       value: Map.get(params, "search", "")
     })
     |> load_packages(change.id)}
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

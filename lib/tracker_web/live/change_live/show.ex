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
    * Drops the inline "timeline" strip below the DAG.
    * Hides propagation entirely until the change is merged.
    * Replaces the dl + <mark> state with a status pill.
    * Renders the DAG without column headers (the labels were
      cluttering and not helping comprehension).

  Affected options are folded to two-segment prefixes
  (e.g. `services.nginx.virtualHosts` → `services.nginx`) with a count,
  so large PRs don't drown the page in individual option names. The set
  is scoped to the current lens's channel revision (defaulting to the
  channel's latest revision when the lens has no explicit revision) —
  without that scope the join fans out across every channel revision an
  option has ever appeared in.
  """

  use TrackerWeb, :live_view

  alias TrackerWeb.DataTable
  alias TrackerWeb.PageSearch
  alias TrackerWeb.PropagationDag
  alias TrackerWeb.PropagationTree
  alias TrackerWeb.TableParams
  alias Tracker.Nixpkgs.Propagation
  alias Tracker.Notifications.ChangeSubscription

  @impl true
  def render(assigns) do
    ~H"""
    <div class="change-show">
      <header class="change-head">
        <div class="change-head-row cm-headrow">
          <span class={"pill pill--lg pill-#{@change.state}"}>
            <span class="dot" aria-hidden="true"></span>
            {@change.state}
          </span>
          <a href={@change.url} target="_blank" rel="noopener noreferrer" class="change-prnum mono">
            #{@change.number}
          </a>
          <span class="cm-arrow muted">→</span>
          <code class="cm-base">{@change.base_ref}</code>
          <button
            :if={@current_user}
            id="subscribe-toggle"
            type="button"
            phx-click="toggle-subscription"
          >
            {if @subscribed?, do: "Unsubscribe", else: "Subscribe"}
          </button>
        </div>
        <h1 class="cm-title">{@change.title}</h1>
      </header>

      <section
        :if={@change.state == :merged and @lifecycle_dag.nodes != []}
        class="change-card change-card-prop m4-prop"
      >
        <div class="change-card-head m4-prop-side">
          <div class="m4-prop-num">
            {@landed_count}<small>/{@total_branches}</small>
          </div>
          <div class="m4-prop-label">
            <small class="muted">
              <strong>{@landed_count}</strong> of {@total_branches} channels reached
            </small>
            <span class="m4-prop-label-mobile">channels reached</span>
          </div>
        </div>
        <div class="m4-prop-track">
          <div class="m4-prop-bar">
            <i style={"width: #{progress_pct(@landed_count, @total_branches)}%"}></i>
          </div>
          <div class="m4-prop-foot">
            merged {merged_ago_text(@change.merged_at)}
          </div>
        </div>
        <div class="change-dag-desktop">
          <PropagationDag.dag dag={@lifecycle_dag} branch_links={@branch_links} />
        </div>
      </section>

      <div class="m3-tabs" id={"cmtabs-#{@change.number}"} phx-hook="ChangeTabs">
        <input
          type="radio"
          name={"cmtab-#{@change.number}"}
          id={"cmtab-chans-#{@change.number}"}
          class="m4tab m4tab-chans"
          checked={@default_tab == :channels}
          disabled={not @channels_enabled?}
        />
        <input
          type="radio"
          name={"cmtab-#{@change.number}"}
          id={"cmtab-pkgs-#{@change.number}"}
          class="m4tab m4tab-pkgs"
          checked={@default_tab == :packages}
          disabled={not @packages_enabled?}
        />
        <input
          type="radio"
          name={"cmtab-#{@change.number}"}
          id={"cmtab-opts-#{@change.number}"}
          class="m4tab m4tab-opts"
          disabled={not @options_enabled?}
        />
        <input
          type="radio"
          name={"cmtab-#{@change.number}"}
          id={"cmtab-info-#{@change.number}"}
          class="m4tab m4tab-info"
          checked={@default_tab == :info}
        />
        <div class="m3-tabs-bar" role="tablist">
          <label
            for={"cmtab-chans-#{@change.number}"}
            class={["m3-tab m3-tab-chans", not @channels_enabled? && "is-disabled"]}
          >
            Channels
          </label>
          <label
            for={"cmtab-pkgs-#{@change.number}"}
            class={["m3-tab m3-tab-pkgs", not @packages_enabled? && "is-disabled"]}
          >
            Packages
          </label>
          <label
            for={"cmtab-opts-#{@change.number}"}
            class={["m3-tab m3-tab-opts", not @options_enabled? && "is-disabled"]}
          >
            Options
          </label>
          <label for={"cmtab-info-#{@change.number}"} class="m3-tab m3-tab-info">Info</label>
        </div>

        <div class="m3-panel m3-panel-chans">
          <PropagationTree.tree
            :if={@propagation_tree}
            tree={@propagation_tree}
            branch_links={@branch_links}
          />
        </div>

        <div class="m3-panel m3-panel-pkgs">
          <section class="change-section">
            <%= if @packages_enabled? do %>
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
                    name="package_search"
                    value={@table_params.search}
                    placeholder="Filter packages…"
                    phx-debounce="300"
                  />
                </form>
              </div>

              <p :if={@change.processing_status != :processed}>
                {processing_status_explanation(@change.processing_status, @change)}
              </p>

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
                prev_path={
                  TableParams.page_path(
                    @table_params,
                    @pkg_current_page - 1,
                    "/changes/#{@change.number}"
                  )
                }
                next_path={
                  TableParams.page_path(
                    @table_params,
                    @pkg_current_page + 1,
                    "/changes/#{@change.number}"
                  )
                }
              />
            <% end %>
          </section>
        </div>

        <div class="m3-panel m3-panel-opts">
          <p :if={@change.files_over_limit} class="change-files-over-limit muted">
            This PR touched too many files to track per-file links — the affected
            options view is disabled. (Usually means the branch is far out of date
            with the base and GitHub's file diff ballooned.)
          </p>

          <section :if={@options_enabled?} class="change-section">
            <div class="change-section-head">
              <h2>
                Affected options <small class="muted">({@option_total})</small>
              </h2>
            </div>

            <.table id="affected-options" rows={@option_prefixes_top}>
              <:col :let={{prefix, _count}} label="Namespace">
                <.link navigate={~p"/options/#{prefix}"} class="mono">{prefix}</.link>
              </:col>
            </.table>

            <p :if={@option_prefix_more > 0} class="muted">
              …and {@option_prefix_more} more {pluralize_namespaces(@option_prefix_more)}
            </p>
          </section>
        </div>

        <div class="m3-panel m3-panel-info">
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

          <div :if={@change.labels && @change.labels != []} class="change-labels">
            <span :for={label <- @change.labels} class="label-chip">{label}</span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp progress_pct(_, 0), do: 0
  defp progress_pct(landed, total), do: round(landed / total * 100)

  defp merged_ago_text(nil), do: "—"

  defp merged_ago_text(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)
    relative(diff)
  end

  defp relative(s) when s < 60, do: "just now"
  defp relative(s) when s < 3600, do: "#{div(s, 60)}m ago"
  defp relative(s) when s < 86_400, do: "#{div(s, 3600)}h ago"
  defp relative(s) when s < 86_400 * 30, do: "#{div(s, 86_400)}d ago"
  defp relative(s) when s < 86_400 * 365, do: "#{div(s, 86_400 * 30)}mo ago"
  defp relative(s), do: "#{div(s, 86_400 * 365)}y ago"

  defp format_datetime(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  defp pluralize_namespaces(1), do: "namespace"
  defp pluralize_namespaces(_), do: "namespaces"

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

  defp processing_status_explanation(:failed_workflow_run, _),
    do: "The upstream nixpkgs-review workflow run completed unsuccessfully for this change."

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
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Tracker.PubSub, "changes:updated")
      Phoenix.PubSub.subscribe(Tracker.PubSub, "change_branches:updated")
    end

    {:ok,
     socket
     |> assign_new(:current_user, fn -> nil end)
     |> assign(:subscribed?, false)}
  end

  @impl true
  def handle_params(%{"number" => number_str} = params, _url, socket) do
    number = String.to_integer(number_str)
    tp = TableParams.from_params(params, search_key: :package_search)

    {:noreply,
     socket
     |> assign(:table_params, tp)
     |> assign(:page_search, %PageSearch{
       mode: :passthrough,
       action: "/changes",
       value: Map.get(params, "search", "")
     })
     |> load_change(number)}
  end

  defp load_change(socket, number) do
    change =
      number
      |> Tracker.Nixpkgs.Change.get_by_number!()
      |> Ash.load!(change_branches: [channel_revision: [:channel]])

    author_maintainer = find_maintainer(change.author_github_id)
    merger_maintainer = find_maintainer(change.merged_by_github_id)

    present_branches = Enum.map(change.change_branches, & &1.branch_name)
    lifecycle_dag = Propagation.lifecycle(change.base_ref, present_branches)
    branch_links = build_branch_links(change.change_branches)

    landed_count = Enum.count(lifecycle_dag.nodes, & &1.present)
    total_branches = length(lifecycle_dag.nodes)

    propagation_tree =
      if change.state == :merged do
        PropagationTree.build(lifecycle_dag, mine_branch: lens_branch_name(socket.assigns[:lens]))
      end

    channels_enabled? = change.state == :merged and lifecycle_dag.nodes != []

    socket
    |> assign(:page_title, "##{change.number} #{change.title}")
    |> assign(:change, change)
    |> assign(:subscribed?, change_subscribed?(socket.assigns[:current_user], change.id))
    |> assign(:author_maintainer, author_maintainer)
    |> assign(:merger_maintainer, merger_maintainer)
    |> assign(:lifecycle_dag, lifecycle_dag)
    |> assign(:branch_links, branch_links)
    |> assign(:landed_count, landed_count)
    |> assign(:total_branches, total_branches)
    |> assign(:propagation_tree, propagation_tree)
    |> assign(:channels_enabled?, channels_enabled?)
    |> load_packages(change.id)
    |> load_options(change.id)
  end

  defp change_subscribed?(nil, _change_id), do: false

  defp change_subscribed?(user, change_id) do
    case ChangeSubscription.find(change_id, nil, actor: user) do
      {:ok, nil} -> false
      {:ok, _subscription} -> true
    end
  end

  defp lens_branch_name(nil), do: nil
  defp lens_branch_name(%{channel: %{name: name}}), do: name
  defp lens_branch_name(_), do: nil

  defp rebuild_propagation_tree(socket) do
    tree =
      if socket.assigns.change.state == :merged do
        PropagationTree.build(socket.assigns.lifecycle_dag,
          mine_branch: lens_branch_name(socket.assigns[:lens])
        )
      end

    assign(socket, :propagation_tree, tree)
  end

  defp build_branch_links(change_branches) do
    for %{branch_name: name, channel_revision: %{revision: rev, channel: %{name: ch_name}}} <-
          change_branches,
        into: %{} do
      {name, %PropagationDag.BranchLink{channel_name: ch_name, revision: rev}}
    end
  end

  @impl true
  def handle_event("toggle-subscription", _params, socket) do
    %{current_user: user, change: change} = socket.assigns

    subscribed? =
      case ChangeSubscription.find(change.id, nil, actor: user) do
        {:ok, nil} ->
          {:ok, _subscription} = ChangeSubscription.subscribe(change.id, nil, actor: user)
          true

        {:ok, subscription} ->
          :ok = ChangeSubscription.destroy(subscription, actor: user)
          false
      end

    {:noreply, assign(socket, :subscribed?, subscribed?)}
  end

  @impl true
  def handle_event("search-packages", %{"package_search" => search}, socket) do
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
    |> stream(:packages, TrackerWeb.PackageRows.with_current_descriptions(page.results),
      reset: true
    )
    |> assign(:package_count, package_count)
    |> assign(
      :packages_enabled?,
      socket.assigns.change.processing_status == :processed and package_count > 0
    )
    |> assign(:pkg_has_prev?, tp.offset > 0)
    |> assign(:pkg_has_next?, page.more?)
    |> assign(:pkg_total_pages, total_pages)
    |> assign(:pkg_current_page, tp.page)
    |> assign_default_tab()
  end

  defp assign_default_tab(socket) do
    search_active? = (socket.assigns.table_params.search || "") != ""

    default_tab =
      cond do
        search_active? and socket.assigns.packages_enabled? -> :packages
        socket.assigns.channels_enabled? -> :channels
        true -> :info
      end

    assign(socket, :default_tab, default_tab)
  end

  @option_prefix_cap 20

  defp load_options(socket, change_id) do
    prefixes =
      case lens_channel_revision_id(socket.assigns[:lens]) do
        nil ->
          []

        cr_id ->
          Tracker.Nixpkgs.Option.prefix_counts_by_change_and_channel_revision(change_id, cr_id)
      end

    top =
      prefixes
      |> Enum.sort_by(fn {prefix, count} -> {-count, prefix} end)
      |> Enum.take(@option_prefix_cap)

    namespace_total = length(prefixes)
    option_total = Enum.reduce(prefixes, 0, fn {_p, count}, acc -> acc + count end)

    change = socket.assigns.change

    options_enabled? =
      change.processing_status == :processed and not change.files_over_limit and top != []

    socket
    |> assign(:option_prefixes_top, top)
    |> assign(:option_total, option_total)
    |> assign(:option_prefix_more, max(namespace_total - length(top), 0))
    |> assign(:options_enabled?, options_enabled?)
  end

  defp lens_channel_revision_id(nil), do: nil
  defp lens_channel_revision_id(%{revision: %{id: id}}), do: id

  defp lens_channel_revision_id(%{channel: %{id: channel_id}}) do
    case Tracker.Nixpkgs.ChannelRevision.latest_by_channel(channel_id) do
      {:ok, cr} -> cr.id
      _ -> nil
    end
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
    socket = TrackerWeb.LensHandlers.handle_lens_change(socket, channel_name, rev)

    socket =
      socket
      |> rebuild_propagation_tree()
      |> load_options(socket.assigns.change.id)

    {:noreply, socket}
  end

  def handle_info(
        %Ash.Notifier.Notification{
          resource: Tracker.Nixpkgs.Change,
          data: %{number: number}
        },
        socket
      ) do
    if number == socket.assigns.change.number do
      {:noreply, load_change(socket, number)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        %Ash.Notifier.Notification{
          resource: Tracker.Nixpkgs.ChangeBranch,
          data: %{change_id: change_id}
        },
        socket
      ) do
    if change_id == socket.assigns.change.id do
      {:noreply, load_change(socket, socket.assigns.change.number)}
    else
      {:noreply, socket}
    end
  end
end

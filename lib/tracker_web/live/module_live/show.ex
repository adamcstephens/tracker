defmodule TrackerWeb.ModuleLive.Show do
  use TrackerWeb, :live_view

  import TrackerWeb.CodeHighlight

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      {@module.display_name}
      <:subtitle>Module</:subtitle>
    </.header>

    <.list>
      <:item title="Declaration">
        <code>{@module.declaration}</code>
      </:item>
    </.list>

    <section :if={@packages != []}>
      <h2>Packages</h2>
      <ul>
        <li :for={pkg <- @packages}>
          <.link navigate={~p"/packages/#{pkg.attribute}"}>{pkg.attribute}</.link>
          <small :if={pkg.description}> —        {pkg.description}</small>
        </li>
      </ul>
    </section>

    <h2>Options ({@option_count})</h2>

    <div :for={{id, option} <- @streams.options} id={id}>
      <article id={"opt-#{option.name}"} style="margin-bottom: 1.5rem;">
        <header>
          <strong>{option.name}</strong>
          <span :if={@revisions[option.id]} style="margin-left: 0.5rem;">
            <kbd>{@revisions[option.id].type}</kbd>
          </span>
          <kbd
            :if={@revisions[option.id] && @revisions[option.id].read_only}
            style="margin-left: 0.25rem;"
          >
            read-only
          </kbd>
        </header>

        <div :if={rev = @revisions[option.id]}>
          <p :if={rev.description}>{rev.description}</p>

          <dl>
            <dt :if={rev.default}>Default</dt>
            <dd :if={rev.default}><.code_block code={rev.default} /></dd>

            <dt :if={rev.example}>Example</dt>
            <dd :if={rev.example}><.code_block code={rev.example} /></dd>
          </dl>
        </div>

        <div :if={option.packages != []}>
          <small>
            Packages:
            <span :for={pkg <- option.packages}>
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

    <.back navigate={~p"/modules"}>Back to modules</.back>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_new(socket, :current_user, fn -> nil end)}
  end

  @impl true
  def handle_params(%{"name" => name} = params, _url, socket) do
    mod = Tracker.Nixpkgs.Module.get_by_name!(name)

    page_num = params |> Map.get("page", "1") |> String.to_integer() |> max(1)
    offset = (page_num - 1) * 15

    options_page =
      Tracker.Nixpkgs.Option.list_by_module!(mod.id,
        page: [offset: offset, count: true]
      )

    total_pages = ceil(options_page.count / 15)

    # Load latest revision for each option on this page
    option_ids = Enum.map(options_page.results, & &1.id)

    revisions =
      option_ids
      |> Tracker.Nixpkgs.OptionRevision.latest_by_option_ids!()
      |> Map.new(&{&1.option_id, &1})

    packages = Tracker.Nixpkgs.Package.by_module!(mod.id)

    {:noreply,
     socket
     |> assign(:page_title, mod.display_name)
     |> assign(:module, mod)
     |> assign(:packages, packages)
     |> assign(:option_count, options_page.count)
     |> assign(:revisions, revisions)
     |> stream(:options, options_page.results, reset: true)
     |> assign(:has_prev_page?, offset > 0)
     |> assign(:has_next_page?, options_page.more?)
     |> assign(:total_pages, total_pages)
     |> assign(:current_page, div(offset, 15) + 1)}
  end

  @impl true
  def handle_event("next-page", _params, socket) do
    {:noreply,
     push_patch(socket,
       to: show_path(socket.assigns.module.display_name, socket.assigns.current_page + 1)
     )}
  end

  @impl true
  def handle_event("prev-page", _params, socket) do
    {:noreply,
     push_patch(socket,
       to: show_path(socket.assigns.module.display_name, max(socket.assigns.current_page - 1, 1))
     )}
  end

  defp show_path(name, page) do
    params =
      %{}
      |> then(fn p -> if page > 1, do: Map.put(p, :page, page), else: p end)

    case URI.encode_query(params) do
      "" -> "/modules/#{name}"
      qs -> "/modules/#{name}?#{qs}"
    end
  end
end

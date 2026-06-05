defmodule TrackerWeb.Layouts do
  @moduledoc """
  This module holds different layouts used by your application.

  See the `layouts` directory for all templates available.
  The "root" layout is a skeleton rendered as part of the
  application router. The "app" layout is set as the default
  layout on both `use TrackerWeb, :controller` and
  `use TrackerWeb, :live_view`.
  """
  use TrackerWeb, :html

  embed_templates "layouts/*"

  defmodule NavItem do
    @moduledoc """
    One chrome navigation entry, shared by both nav renders.

    `context` controls which breakpoint shows the item (CSS hides the others);
    `full`/`short` are the desktop and mobile labels. A non-empty `children`
    list turns the entry into a disclosure (the mobile "More" dropdown).
    """
    use TypedStruct

    typedstruct enforce: true do
      field :path, String.t()
      field :active, [String.t()]
      field :context, :both | :desktop | :mobile
      field :full, String.t() | nil, enforce: false
      field :short, String.t() | nil, enforce: false
      field :children, list(), default: []
    end
  end

  @doc """
  The single ordered source for the chrome section navigation.

  Order follows the desktop layout. The desktop tabs render the `:both` and
  `:desktop` entries; the mobile bar renders `:both` and `:mobile`. CSS hides
  the off-breakpoint cells, so one render serves both.
  """
  def nav_items(current_user) do
    more_group = more_group(current_user)

    [
      %NavItem{
        path: "/packages",
        full: "Packages",
        short: "Pkgs",
        active: ["PackageLive"],
        context: :both
      },
      %NavItem{
        path: "/channels",
        full: "Channels",
        short: "Chans",
        active: ["ChannelLive"],
        context: :both
      },
      %NavItem{
        path: "/options",
        full: "Options",
        short: "Options",
        active: ["OptionLive"],
        context: :both
      },
      %NavItem{
        path: "/changes",
        full: "Changes",
        short: "Changes",
        active: ["ChangeLive"],
        context: :both
      }
    ] ++
      more_group ++
      [
        %NavItem{
          path: "/maintainers",
          short: "More",
          active: Enum.flat_map(more_group, & &1.active) |> Enum.uniq(),
          context: :mobile,
          children: more_group
        }
      ]
  end

  # Sections that are top-level tabs on desktop, but collapse into the mobile
  # "More" dropdown. Defined once so both renders share the same source.
  defp more_group(current_user) do
    [
      %NavItem{
        path: "/maintainers",
        full: "Maintainers",
        active: ["MaintainerLive"],
        context: :desktop
      },
      %NavItem{path: "/teams", full: "Teams", active: ["TeamLive"], context: :desktop}
    ] ++ admin_items(current_user)
  end

  defp admin_items(current_user) do
    if current_user && Tracker.Accounts.User.has_role?(current_user, :admin) do
      # aria-current here mirrors the prior layout's quirk (checks TeamLive);
      # preserved as-is and tracked separately.
      [%NavItem{path: "/admin", full: "Admin", active: ["TeamLive"], context: :desktop}]
    else
      []
    end
  end

  @doc """
  Whether `view` falls under any of the nav item's active view prefixes.
  """
  def nav_active?(view, %NavItem{active: prefixes}) do
    Enum.any?(prefixes, &active_nav?(view, &1))
  end

  attr :current_user, :any, default: nil
  attr :view, :atom, required: true
  attr :search, :string, default: ""

  @doc """
  Renders the chrome section navigation once for both breakpoints.

  CSS picks the per-breakpoint label (`app-tab__full`/`app-tab__short`) and
  hides the off-breakpoint cells via `is-desktop-only`/`is-mobile-only`.
  """
  def app_nav(assigns) do
    assigns = assign(assigns, :items, nav_items(assigns.current_user))

    ~H"""
    <nav class="app-nav" aria-label="Primary">
      <ul class="app-tabs">
        <li :for={item <- @items} class={nav_item_class(item)}>
          <.link
            :if={item.children == []}
            navigate={nav_path(item.path, @search)}
            aria-current={nav_active?(@view, item) && "page"}
          >
            <span :if={item.full} class="app-tab__full">{item.full}</span>
            <span :if={item.short} class="app-tab__short">{item.short}</span>
          </.link>
          <details :if={item.children != []} class="app-more">
            <summary class="app-more__summary" aria-current={nav_active?(@view, item) && "page"}>
              <span class="app-tab__short">{item.short}</span>
              <span class="app-more__caret" aria-hidden="true">▾</span>
            </summary>
            <div class="app-more__panel">
              <.link
                :for={child <- item.children}
                navigate={nav_path(child.path, @search)}
                aria-current={nav_active?(@view, child) && "page"}
              >
                {child.full}
              </.link>
            </div>
          </details>
        </li>
      </ul>
    </nav>
    """
  end

  defp nav_item_class(%NavItem{context: :desktop}), do: "is-desktop-only"
  defp nav_item_class(%NavItem{context: :mobile}), do: "is-mobile-only"
  defp nav_item_class(%NavItem{context: :both}), do: nil

  def active_nav?(view, prefix) when is_atom(view) do
    case Module.split(view) do
      [_, ^prefix | _] -> true
      _ -> false
    end
  end

  def active_nav?(_view, _prefix), do: false

  @doc """
  Returns up to two uppercase initials for a given name, used as the
  monogram in the user chip avatar when a GitHub avatar is unavailable.
  """
  def monogram(name) when is_binary(name) and byte_size(name) > 0 do
    name
    |> String.graphemes()
    |> Enum.take(2)
    |> Enum.map_join("", &String.upcase/1)
  end

  def monogram(_), do: ""

  @doc """
  Decorates a chrome navigation path with the persisted `?search=` param
  so the global search query carries across section navigations.
  """
  def nav_path(path, ""), do: path
  def nav_path(path, nil), do: path

  def nav_path(path, search) when is_binary(search) do
    "#{path}?#{URI.encode_query(%{search: search})}"
  end
end

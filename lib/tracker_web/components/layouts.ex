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
      # /admin routes to AshAdmin (AshAdmin.* namespace), which active_nav?/2
      # can't match, so the tab carries no active prefix of its own.
      [%NavItem{path: "/admin", full: "Admin", active: [], context: :desktop}]
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
  The inbox icon's unread badge text: capped at `99+`, `nil` when there is
  nothing unread (the badge is hidden at zero).
  """
  def inbox_badge(assigns) do
    case assigns[:unread_notification_count] || 0 do
      0 -> nil
      count when count > 99 -> "99+"
      count -> Integer.to_string(count)
    end
  end

  attr :id, :string, required: true
  attr :class, :string, default: nil
  attr :view, :atom, required: true
  attr :badge, :string, default: nil

  @doc """
  The inbox link with its unread badge, rendered once per breakpoint: in the
  top row for desktop and on the lens row for mobile (CSS hides the
  off-breakpoint instance).
  """
  def inbox_link(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={~p"/inbox"}
      class={["app-inbox", @class]}
      title="Inbox"
      aria-label="Inbox"
      aria-current={active_nav?(@view, "InboxLive") && "page"}
    >
      <svg
        class="app-inbox__icon"
        aria-hidden="true"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="1.7"
        stroke-linecap="round"
        stroke-linejoin="round"
      >
        <path d="M4 13h4l2 3h4l2-3h4" />
        <path d="M5 5h14a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2Z" />
      </svg>
      <span :if={@badge} class="app-inbox__badge">{@badge}</span>
    </.link>
    """
  end

  attr :user, :any, required: true

  @doc """
  The user's GitHub avatar, falling back to a monogram of their username.
  Shared by the desktop user chip and the mobile avatar disclosure.
  """
  def user_avatar(assigns) do
    ~H"""
    <%= if @user.github_id do %>
      <img
        class="app-user__avatar"
        src={"https://avatars.githubusercontent.com/u/#{@user.github_id}?v=4&s=64"}
        alt=""
        aria-hidden="true"
      />
    <% else %>
      <span class="app-user__avatar app-user__avatar--monogram" aria-hidden="true">
        {monogram(@user.github_username)}
      </span>
    <% end %>
    """
  end

  @doc """
  The account-menu panel (Settings, API tokens, Sign out), shared by the
  desktop user chip and the mobile avatar disclosure.
  """
  def user_menu_panel(assigns) do
    ~H"""
    <div class="app-user__panel" role="menu">
      <.link navigate={~p"/account/settings"} class="app-user__menu-item" role="menuitem">
        Settings
      </.link>
      <.link navigate={~p"/account/tokens"} class="app-user__menu-item" role="menuitem">
        API tokens
      </.link>
      <.link href={~p"/sign-out"} method="delete" class="app-user__menu-item" role="menuitem">
        Sign out
      </.link>
    </div>
    """
  end

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

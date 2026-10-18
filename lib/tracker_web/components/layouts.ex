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
    One chrome navigation entry shared across breakpoints.

    `full`/`short` are the desktop and mobile labels. A non-empty `children`
    list turns the entry into a native disclosure.
    """
    use TypedStruct

    typedstruct enforce: true do
      field :path, String.t()
      field :active, [String.t()]
      field :full, String.t() | nil, enforce: false
      field :short, String.t() | nil, enforce: false
      field :children, list(), default: []
    end
  end

  defmodule Shortcut do
    @moduledoc """
    One keyboard shortcut row in the `?` overlay.

    `keys` renders one `<kbd>` each — a chord like `g p` is a single entry,
    since the two keys are pressed in sequence rather than together.
    """
    use TypedStruct

    typedstruct enforce: true do
      field :keys, [String.t()]
      field :label, String.t()
    end
  end

  defmodule ShortcutGroup do
    @moduledoc "A titled section of the `?` overlay."
    use TypedStruct

    typedstruct enforce: true do
      field :title, String.t()
      field :shortcuts, [Shortcut.t()]
    end
  end

  @doc """
  The single ordered source for the `?` overlay.

  The handlers themselves live in `assets/js/ui.js`; this is the list the
  overlay renders, so adding a shortcut means touching both.
  """
  def shortcut_groups do
    [
      %ShortcutGroup{
        title: "Site navigation",
        shortcuts: [
          %Shortcut{keys: ["g p"], label: "Packages"},
          %Shortcut{keys: ["g o"], label: "Options"},
          %Shortcut{keys: ["g c"], label: "Changes"},
          %Shortcut{keys: ["g n"], label: "Inbox"},
          %Shortcut{keys: ["u", "h"], label: "Up a level (options)"}
        ]
      },
      %ShortcutGroup{
        title: "Lists",
        shortcuts: [
          %Shortcut{keys: ["j", "↓"], label: "Next row"},
          %Shortcut{keys: ["k", "↑"], label: "Previous row"},
          %Shortcut{keys: ["Enter"], label: "Open the focused row"},
          %Shortcut{keys: ["m"], label: "Toggle read (inbox)"},
          %Shortcut{keys: ["s"], label: "Toggle save (inbox)"}
        ]
      },
      %ShortcutGroup{
        title: "General",
        shortcuts: [
          %Shortcut{keys: ["v"], label: "Open on GitHub"},
          %Shortcut{keys: ["#"], label: "Open the channel lens"},
          %Shortcut{keys: ["/"], label: "Focus search"},
          %Shortcut{keys: ["Esc"], label: "Leave search"},
          %Shortcut{keys: ["?"], label: "This list"}
        ]
      }
    ]
  end

  @doc """
  The `?` overlay. Rendered once in the app layout so it exists on every page.

  A native `<dialog>`: `showModal()` brings the backdrop, focus trap, and
  Escape-to-close with it, and makes the rest of the page inert.
  """
  def shortcuts_dialog(assigns) do
    assigns = assign(assigns, :groups, shortcut_groups())

    ~H"""
    <dialog id="shortcuts" aria-labelledby="shortcuts-title">
      <div class="card shortcuts">
        <header>
          <h2 id="shortcuts-title">Keyboard shortcuts</h2>
          <form method="dialog">
            <button class="shortcuts__close" aria-label="Close">×</button>
          </form>
        </header>
        <div class="shortcuts__groups">
          <section :for={group <- @groups}>
            <h3>{group.title}</h3>
            <dl>
              <div :for={shortcut <- group.shortcuts} class="shortcuts__row">
                <dt>
                  <kbd :for={key <- shortcut.keys}>{key}</kbd>
                </dt>
                <dd>{shortcut.label}</dd>
              </div>
            </dl>
          </section>
        </div>
      </div>
    </dialog>
    """
  end

  @doc """
  The single ordered source for the chrome section navigation.

  Four primary sections followed by the More disclosure at every breakpoint.
  """
  def nav_items(current_user) do
    more_group = more_group(current_user)

    [
      %NavItem{
        path: "/packages",
        full: "Packages",
        short: "Pkgs",
        active: ["PackageLive"]
      },
      %NavItem{
        path: "/changes",
        full: "Changes",
        short: "Chgs",
        active: ["ChangeLive"]
      },
      %NavItem{
        path: "/channels",
        full: "Channels",
        short: "Chans",
        active: ["ChannelLive"]
      },
      %NavItem{
        path: "/options",
        full: "Options",
        short: "Opts",
        active: ["OptionLive"]
      },
      %NavItem{
        path: "/maintainers",
        full: "More",
        active: Enum.flat_map(more_group, & &1.active) |> Enum.uniq(),
        children: more_group
      }
    ]
  end

  # Secondary sections live only in More, at every breakpoint.
  defp more_group(current_user) do
    [
      %NavItem{
        path: "/maintainers",
        full: "Maintainers",
        active: ["MaintainerLive"]
      },
      %NavItem{path: "/teams", full: "Teams", active: ["TeamLive"]}
    ] ++ admin_items(current_user)
  end

  defp admin_items(current_user) do
    if current_user && Tracker.Accounts.User.has_role?(current_user, :admin) do
      [%NavItem{path: "/admin", full: "Admin", active: ["AdminLive"]}]
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

  CSS picks the per-breakpoint label (`app-tab__full`/`app-tab__short`).
  """
  def app_nav(assigns) do
    assigns = assign(assigns, :items, nav_items(assigns.current_user))

    ~H"""
    <nav class="app-nav" aria-label="Primary">
      <ul class="app-tabs">
        <li :for={item <- @items}>
          <.link
            :if={item.children == []}
            navigate={nav_path(item.path, @search)}
            aria-label={item.full}
            aria-current={nav_active?(@view, item) && "page"}
          >
            <span :if={item.full} class="app-tab__full">{item.full}</span>
            <span :if={item.short} class="app-tab__short">{item.short}</span>
          </.link>
          <details :if={item.children != []} class="app-more">
            <summary class="app-more__summary" aria-current={nav_active?(@view, item) && "page"}>
              <span>{item.full}</span>
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
      <span
        class="svg-icon app-inbox__icon"
        aria-hidden="true"
        style={"--icon-url: url('#{~p"/images/inbox.svg"}')"}
      ></span>
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

  @doc """
  The current page without its search query — where the search box's clear
  button lands. Hidden params (sort, filters) survive as query params.
  """
  def clear_search_path(%TrackerWeb.PageSearch{action: action, hidden: hidden})
      when map_size(hidden) == 0,
      do: action

  def clear_search_path(%TrackerWeb.PageSearch{action: action, hidden: hidden}) do
    "#{action}?#{URI.encode_query(hidden)}"
  end
end

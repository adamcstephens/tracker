defmodule TrackerWeb.LayoutsTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Tracker.Accounts.User
  alias Tracker.Nixpkgs.Channel
  alias TrackerWeb.Layouts
  alias TrackerWeb.Layouts.NavItem

  setup do
    suffix = System.unique_integer([:positive])

    Channel.create!(%{
      name: "nixos-25.#{suffix}",
      display_name: "NixOS 25.#{suffix}",
      status: :active,
      is_stable: true
    })

    :ok
  end

  describe "app chrome" do
    test "renders two-row chrome with brand, tabs, and lens", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/changes")

      assert html =~ ~s(class="app-header")
      assert html =~ ~s(class="app-header__row app-header__row--top")
      assert html =~ ~s(class="app-header__row app-header__row--bottom")
      assert html =~ ~s(class="app-brand")
      assert html =~ "Tracker"
    end

    test "tabs row contains all six sections", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/changes")

      for label <- ~w(Packages Channels Options Changes Maintainers Teams) do
        assert html =~ label
      end
    end

    test "active tab is marked aria-current=page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/changes")

      assert html =~ ~s(aria-current="page")
    end

    test "renders sign-in link when no current user", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/changes")

      assert html =~ "Sign in"
    end

    test "lens chip lives in the bottom row of the chrome", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/changes")

      assert html =~ ~s(id="lens")
      # Lens lives within the bottom row container
      assert html =~ ~r{app-header__row--bottom.*?id="lens"}s
    end
  end

  describe "page-search slot" do
    test "renders a search input in the chrome on Changes", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/changes")

      # Search input lifted from page body into the chrome's bottom row.
      assert html =~ ~r{app-header__row--bottom.*?<form[^>]*method="get"[^>]*action="/changes"}s
      assert html =~ ~s(placeholder="Search…")
      assert html =~ ~s(name="search")
    end

    test "renders a search input in the chrome on Packages", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/packages")

      assert html =~ ~r{app-header__row--bottom.*?action="/packages"}s
      assert html =~ ~s(placeholder="Search…")
    end

    test "Channels page renders an inert (disabled) search box", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/channels")

      # Search box is still rendered as part of the chrome on every page,
      # but on Channels it has no meaningful target — render disabled.
      assert html =~ ~r{app-header__row--bottom.*?<form[^>]*class="[^"]*app-search[^"]*"}s
      assert html =~ ~r{app-search--inert}
      assert html =~ ~r{<input[^>]*type="search"[^>]*disabled}
    end

    test "Changes search form preserves base_ref via hidden input", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/changes?base_ref=master")

      assert html =~
               ~r{app-header__row--bottom.*?<input[^>]*type="hidden"[^>]*name="base_ref"[^>]*value="master"}s
    end

    test "search form has a submit button so it works without JS", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/packages")

      [form] =
        html
        |> Floki.parse_document!()
        |> Floki.find("form#page-search")

      assert Floki.find(form, "button[type=submit]") != []
    end

    test "page no longer renders its own search input on Changes", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/changes")

      # No "change-filters" form id (it lifts to the chrome) — but the page
      # may still render a base_ref filter form. Assert specifically that
      # the page body has no <input type="search">.
      [_layout, body] = String.split(html, "app-header__row--bottom", parts: 2)
      [_chrome, page_body] = String.split(body, "<main", parts: 2)
      refute page_body =~ ~s(type="search")
    end

    test "chrome search form mounts the UpdateURL hook for live URL updates", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/packages")

      # Without phx-hook="UpdateURL" mounted, push_event("update-url", …) is
      # silently dropped and the URL never reflects the search query.
      assert html =~
               ~r{app-header__row--bottom.*?<form[^>]*phx-hook="UpdateURL"[^>]*action="/packages"}s
    end

    test "Packages search form preserves sort via hidden inputs", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/packages?sort_by=attribute&sort_dir=asc")

      [_top, bottom] = String.split(html, "app-header__row--bottom", parts: 2)
      [chrome_form, _rest] = String.split(bottom, "</form>", parts: 2)

      assert chrome_form =~ ~s(type="hidden")
      assert chrome_form =~ ~r{<input[^>]*name="sort_by"[^>]*value="attribute"}
      assert chrome_form =~ ~r{<input[^>]*name="sort_dir"[^>]*value="asc"}
    end

    test "Options search form drops page so a fresh search resets to page 1 (trk-278)", %{
      conn: conn
    } do
      {:ok, _view, html} = live(conn, ~p"/options?page=3")

      [_top, bottom] = String.split(html, "app-header__row--bottom", parts: 2)
      [chrome_form, _rest] = String.split(bottom, "</form>", parts: 2)

      refute chrome_form =~ ~r{<input[^>]*type="hidden"[^>]*name="page"}
    end
  end

  describe "global search persistence" do
    test "active page (Packages) seeds the input from ?search=", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/packages?search=elixir")

      assert html =~ ~r{<input[^>]*type="search"[^>]*name="search"[^>]*value="elixir"}
    end

    test "chrome nav links carry the current ?search= across sections", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/packages?search=elixir")

      # Top tabs and mobile tabs both append the current search to navigations,
      # so jumping to /options keeps the query intact.
      assert html =~ ~r{href="/options\?search=elixir"}
      assert html =~ ~r{href="/changes\?search=elixir"}
      assert html =~ ~r{href="/maintainers\?search=elixir"}
      assert html =~ ~r{href="/teams\?search=elixir"}
      assert html =~ ~r{href="/channels\?search=elixir"}
    end

    test "inert page (Channels) still echoes the persisted query", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/channels?search=elixir")

      assert html =~ ~r{<input[^>]*type="search"[^>]*value="elixir"[^>]*disabled}
    end

    test "active page input reflects the new value after a search submit", %{conn: conn} do
      Tracker.Nixpkgs.Package
      |> Ash.Changeset.for_create(:create, %{attribute: "ripgrep"})
      |> Ash.create!()

      {:ok, view, _html} = live(conn, ~p"/packages?search=elixir")

      html =
        view
        |> element("form#page-search")
        |> render_change(%{"search" => "ripgrep"})

      # If the LV doesn't sync :page_search after handling the event, the
      # input snaps back to the previous value on re-render.
      assert html =~ ~r{<input[^>]*type="search"[^>]*value="ripgrep"}
      refute html =~ ~r{<input[^>]*type="search"[^>]*value="elixir"}
    end
  end

  describe "passthrough chrome search on detail pages" do
    setup do
      Tracker.Nixpkgs.Package
      |> Ash.Changeset.for_create(:create, %{attribute: "ripgrep"})
      |> Ash.create!()

      :ok
    end

    test "package detail renders an editable chrome search posting to /packages",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/packages/ripgrep?search=elixir")

      # Form action goes to the parent index, value reflects the persisted query,
      # and there's no UpdateURL hook (passthrough is a plain GET).
      assert html =~ ~r{app-header__row--bottom.*?<form[^>]*method="get"[^>]*action="/packages"}s
      assert html =~ ~r{<input[^>]*type="search"[^>]*value="elixir"}
      refute html =~ ~r{app-header__row--bottom.*?phx-hook="UpdateURL"}s
    end
  end

  describe "polished chrome elements" do
    test "user chip renders as a styled chip when signed out", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/changes")

      assert html =~ ~s(class="app-user__chip")
      assert html =~ "Sign in"
    end

    test "header rows are wrapped in a container for body-aligned width", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/changes")

      assert html =~ ~r{app-header__row--top.*?class="container}s
      assert html =~ ~r{app-header__row--bottom.*?class="container}s
    end
  end

  describe "lens dot prefix" do
    test "renders an indigo dot adjacent to the channel select", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/changes")

      assert html =~ ~s(class="lens-dot")
      # Dot lives in the same cell as the select.
      assert html =~ ~r{lens-channel-cell.*?lens-dot.*?<select}s
    end
  end

  describe "section nav (single source)" do
    test "renders one nav carrying full and short labels", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/changes")

      assert html =~ ~s(class="app-nav")

      # Short (mobile) labels live in dedicated spans alongside the full ones,
      # so one render serves both breakpoints; CSS picks which to show.
      for short <- ~w(Pkgs Chans More) do
        assert html =~ ~r{class="app-tab__short">\s*#{short}}
      end

      for full <- ~w(Packages Channels Maintainers Teams) do
        assert html =~ ~r{class="app-tab__full">\s*#{full}}
      end
    end

    test "tags off-breakpoint cells for CSS hiding", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/changes")

      # Maintainers/Teams are desktop-only; the More collapse is mobile-only.
      assert html =~ ~s(class="is-desktop-only")
      assert html =~ ~s(class="is-mobile-only")
    end

    test "marks the active section with aria-current=page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/changes")

      current =
        html
        |> Floki.parse_document!()
        |> Floki.find(~s(.app-nav a[aria-current="page"]))
        |> Floki.text()

      assert current =~ "Changes"
    end
  end

  describe "mobile More dropdown" do
    test "renders More as a details disclosure listing the desktop sections", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/changes")

      doc = Floki.parse_document!(html)

      assert [_] = Floki.find(doc, "details.app-more")

      panel_links =
        doc
        |> Floki.find(".app-more__panel a")
        |> Enum.map(&(&1 |> Floki.text() |> String.trim()))

      assert "Maintainers" in panel_links
      assert "Teams" in panel_links
    end

    test "marks the active route on both the summary and its panel link", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/maintainers")

      doc = Floki.parse_document!(html)

      assert Floki.find(doc, ~s(summary.app-more__summary[aria-current="page"])) != []

      active_panel =
        doc
        |> Floki.find(~s(.app-more__panel a[aria-current="page"]))
        |> Floki.text()
        |> String.trim()

      assert active_panel =~ "Maintainers"
    end
  end

  describe "nav_items/1 (single nav source)" do
    test "lists sections in desktop order with both/desktop/mobile contexts" do
      items = Layouts.nav_items(nil)

      assert Enum.map(items, & &1.path) == [
               "/packages",
               "/channels",
               "/options",
               "/changes",
               "/maintainers",
               "/teams",
               "/maintainers"
             ]

      assert Enum.map(items, & &1.context) == [
               :both,
               :both,
               :both,
               :both,
               :desktop,
               :desktop,
               :mobile
             ]
    end

    test "common items carry both full and short labels" do
      pkgs = Enum.find(Layouts.nav_items(nil), &(&1.path == "/packages"))

      assert pkgs.full == "Packages"
      assert pkgs.short == "Pkgs"
    end

    test "the mobile-only More entry collapses maintainers and teams" do
      more = Enum.find(Layouts.nav_items(nil), &(&1.context == :mobile))

      assert more.short == "More"
      assert more.path == "/maintainers"
      assert more.active == ["MaintainerLive", "TeamLive"]
    end

    test "the More entry carries the desktop group as dropdown children" do
      more = Enum.find(Layouts.nav_items(nil), &(&1.context == :mobile))

      assert Enum.map(more.children, & &1.path) == ["/maintainers", "/teams"]
      assert Enum.map(more.children, & &1.full) == ["Maintainers", "Teams"]
    end

    test "Admin section appears only for admin users" do
      refute Enum.any?(Layouts.nav_items(nil), &(&1.full == "Admin"))
      refute Enum.any?(Layouts.nav_items(%User{roles: [:user]}), &(&1.full == "Admin"))
      assert Enum.any?(Layouts.nav_items(%User{roles: [:user, :admin]}), &(&1.full == "Admin"))
    end

    test "admin user's More dropdown includes Admin as a child" do
      more = Enum.find(Layouts.nav_items(%User{roles: [:user, :admin]}), &(&1.context == :mobile))

      assert "/admin" in Enum.map(more.children, & &1.path)
    end

    test "Admin tab carries no active prefix so it doesn't share Teams' underline" do
      admin = Enum.find(Layouts.nav_items(%User{roles: [:user, :admin]}), &(&1.full == "Admin"))

      assert admin.active == []
      refute Layouts.nav_active?(TrackerWeb.TeamLive.Index, admin)
    end
  end

  describe "nav_active?/2" do
    test "true when the view matches any of the item's active prefixes" do
      item = %NavItem{
        path: "/maintainers",
        active: ["MaintainerLive", "TeamLive"],
        context: :mobile
      }

      assert Layouts.nav_active?(TrackerWeb.TeamLive.Index, item)
      assert Layouts.nav_active?(TrackerWeb.MaintainerLive.Index, item)
      refute Layouts.nav_active?(TrackerWeb.PackageLive.Index, item)
    end
  end

  describe "list page titles" do
    test "Changes index does not render a redundant page title", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/changes")

      # The active tab + lens chip already convey the scope.
      refute html =~ ~r{<header[^>]*>\s*Changes\s*</header}
    end

    test "Packages index does not render a redundant page title", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/packages")

      # The active tab + lens chip already convey the scope; no <header> wrapper.
      refute html =~ ~r{<hgroup[^>]*>\s*<h1>}
    end
  end
end

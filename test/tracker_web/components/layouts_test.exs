defmodule TrackerWeb.LayoutsTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tracker.Fixtures

  alias AshAuthentication.Plug.Helpers
  alias Tracker.Accounts.User
  alias Tracker.Nixpkgs.Channel
  alias TrackerWeb.Layouts

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

    test "clicking anywhere in the search box focuses the input (trk-305)", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/packages")

      # The styled box is the form, not the input — clicks on its padding,
      # gaps, or "/" hint must still reach the input. A label wrapping the
      # input does this natively, with or without JS.
      [form] =
        html
        |> Floki.parse_document!()
        |> Floki.find("form#page-search")

      [label] = Floki.find(form, "label.app-search__field")
      assert Floki.attribute(label, "for") == ["page-search-input"]
      assert Floki.find(label, "input#page-search-input") != []
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
      # so jumping to /options keeps the query intact. The lens rides along too.
      doc = Floki.parse_document!(html)

      for section <- ~w(/options /changes /maintainers /teams /channels) do
        assert [href | _] = Floki.attribute(doc, ~s(a[href^="#{section}?"]), "href")
        assert URI.decode_query(URI.parse(href).query)["search"] == "elixir"
      end
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

  describe "section navigation" do
    test "renders four ordered primary sections followed by More" do
      doc = navigation()

      assert Floki.attribute(doc, ".app-tabs > li > a", "aria-label") ==
               ["Packages", "Changes", "Channels", "Options"]

      assert Floki.attribute(doc, ".app-tabs > li > a", "href") ==
               ["/packages", "/changes", "/channels", "/options"]

      assert doc
             |> Floki.find(".app-tabs > li:last-child > details > summary")
             |> Floki.text()
             |> String.replace("▾", "")
             |> String.trim() == "More"

      assert Floki.find(doc, ".app-tabs > li") |> length() == 5
      assert Floki.find(doc, "nav") |> length() == 1
    end

    test "abbreviated labels retain full accessible names" do
      doc = navigation()

      assert Floki.find(doc, ".app-tabs > li > a .app-tab__short")
             |> Enum.map(&(Floki.text(&1) |> String.trim())) ==
               ["Pkgs", "Chgs", "Chans", "Opts"]
    end

    test "secondary sections appear only once, inside the native More disclosure" do
      doc = navigation()

      assert Floki.attribute(doc, "details.app-more a", "href") == ["/maintainers", "/teams"]

      for path <- ["/maintainers", "/teams"] do
        assert [_] = Floki.find(doc, ~s(a[href="#{path}"]))
        assert [_] = Floki.find(doc, ~s(details.app-more a[href="#{path}"]))
      end
    end

    test "Admin is available only to administrators and only within More" do
      for user <- [nil, %User{roles: [:user]}] do
        assert Floki.find(navigation(current_user: user), ~s(a[href="/admin"])) == []
      end

      doc = navigation(current_user: %User{roles: [:user, :admin]})
      assert [_] = Floki.find(doc, ~s(a[href="/admin"]))

      assert Floki.attribute(doc, "details.app-more a", "href") ==
               ["/maintainers", "/teams", "/admin"]
    end

    test "primary active state does not activate More" do
      doc = navigation(view: TrackerWeb.ChangeLive.Index)
      assert Floki.attribute(doc, ~s(a[aria-current="page"]), "href") == ["/changes"]
      assert Floki.find(doc, ~s(summary[aria-current="page"])) == []
    end

    test "secondary active state marks More and exactly the matching child" do
      for {view, path} <- [
            {TrackerWeb.MaintainerLive.Show, "/maintainers"},
            {TrackerWeb.TeamLive.Index, "/teams"},
            {TrackerWeb.AdminLive.Ingestion, "/admin"}
          ] do
        doc = navigation(view: view, current_user: %User{roles: [:user, :admin]})
        assert [_] = Floki.find(doc, ~s(details.app-more > summary[aria-current="page"]))
        assert Floki.attribute(doc, ~s(a[aria-current="page"]), "href") == [path]
      end
    end

    test "every primary and secondary destination preserves the search query" do
      search = "hello & nix+pkgs"
      doc = navigation(search: search, current_user: %User{roles: [:user, :admin]})
      links = Floki.attribute(doc, "a", "href")

      assert Enum.map(links, &URI.parse(&1).path) ==
               [
                 "/packages",
                 "/changes",
                 "/channels",
                 "/options",
                 "/maintainers",
                 "/teams",
                 "/admin"
               ]

      for href <- links do
        assert URI.decode_query(URI.parse(href).query) == %{"search" => search}
      end
    end

    defp navigation(opts \\ []) do
      render_component(
        &Layouts.app_nav/1,
        Keyword.merge([view: TrackerWeb.ChangeLive.Index, current_user: nil, search: ""], opts)
      )
      |> Floki.parse_document!()
    end
  end

  describe "mobile identity & inbox (trk-310)" do
    defp log_in(conn, user) do
      conn
      |> Plug.Test.init_test_session(%{})
      |> Helpers.store_in_session(user)
    end

    test "signed out: a mobile sign-in link renders in the search row", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/changes")

      doc = Floki.parse_document!(html)

      [link] = Floki.find(doc, ~s(a[aria-label="Sign in"]))
      assert [href] = Floki.attribute(link, "href")
      assert URI.parse(href).path == "/sign-in"
      assert [class] = Floki.attribute(link, "class")
      assert class =~ "is-mobile-only"

      # Mobile sign-in lives in the bottom (search) row, not the tab row.
      assert html =~ ~r{app-header__row--bottom.*?aria-label="Sign in"}s
    end

    test "signed out: no mobile inbox bell renders", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/changes")

      assert Floki.find(Floki.parse_document!(html), "#inbox-icon-mobile") == []
    end

    test "signed in: the mobile avatar opens the same account menu", %{conn: conn} do
      user = register_user!()
      {:ok, _view, html} = live(log_in(conn, user), ~p"/changes")

      doc = Floki.parse_document!(html)

      [menu] = Floki.find(doc, "details#app-user-menu-mobile")
      assert [class] = Floki.attribute(menu, "class")
      assert class =~ "is-mobile-only"

      items =
        menu
        |> Floki.find(".app-user__menu-item")
        |> Enum.map(&(&1 |> Floki.text() |> String.trim()))

      assert "Settings" in items
      assert "API tokens" in items
      assert "Sign out" in items
    end

    test "signed in: a mobile inbox bell renders on the lens row", %{conn: conn} do
      user = register_user!()
      {:ok, _view, html} = live(log_in(conn, user), ~p"/changes")

      doc = Floki.parse_document!(html)

      [bell] = Floki.find(doc, "#inbox-icon-mobile")
      assert [href] = Floki.attribute(bell, "href")
      assert URI.parse(href).path == "/inbox"
      assert Floki.attribute(bell, "aria-label") == ["Inbox"]

      # The bell sits beside the lens in a shared row wrapper.
      assert [_] = Floki.find(doc, ".app-header__lens-row #inbox-icon-mobile")
      assert [_] = Floki.find(doc, ".app-header__lens-row .app-header__lens-slot")
    end

    test "signed in: the bell renders even on pages without a lens", %{conn: conn} do
      user = register_user!()
      {:ok, _view, html} = live(log_in(conn, user), ~p"/inbox")

      assert [_] = Floki.find(Floki.parse_document!(html), "#inbox-icon-mobile")
    end

    test "signed in: unread count renders as a badge on the mobile bell", %{conn: conn} do
      user = register_user!()
      chan = channel!()
      rev = channel_revision!(chan)

      notification!(user, %{
        type: :channel_revision_published,
        channel_id: chan.id,
        channel_revision_id: rev.id
      })

      {:ok, _view, html} = live(log_in(conn, user), ~p"/changes")

      badge =
        html
        |> Floki.parse_document!()
        |> Floki.find("#inbox-icon-mobile .app-inbox__badge")
        |> Floki.text()
        |> String.trim()

      assert badge == "1"
    end
  end

  describe "keyboard shortcut overlay (TRK-372)" do
    test "the dialog renders on every page, so \"?\" always has something to open",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/changes")
      doc = Floki.parse_document!(html)

      assert [dialog] = Floki.find(doc, "dialog#shortcuts")
      assert Floki.find(dialog, "kbd") != []
    end

    test "every shortcut in the source list reaches the markup", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/changes")

      keys =
        html
        |> Floki.parse_document!()
        |> Floki.find("dialog#shortcuts kbd")
        |> Enum.map(&Floki.text/1)

      for group <- Layouts.shortcut_groups(),
          shortcut <- group.shortcuts,
          key <- shortcut.keys do
        assert key in keys, ~s(shortcut "#{key}" is missing from the overlay)
      end
    end

    test "the groups cover navigation, lists, and the general keys" do
      titles = Enum.map(Layouts.shortcut_groups(), & &1.title)

      assert titles == ["Site navigation", "Lists", "General"]
    end

    test "it documents the jump chords, the row keys, and its own key" do
      keys =
        Layouts.shortcut_groups()
        |> Enum.flat_map(& &1.shortcuts)
        |> Enum.flat_map(& &1.keys)

      for key <- ["g p", "g o", "g c", "g n", "j", "k", "Enter", "/", "?"] do
        assert key in keys
      end
    end

    test "it documents Escape as the way back out of the search box" do
      general = Enum.find(Layouts.shortcut_groups(), &(&1.title == "General"))

      assert %{keys: ["Esc"], label: "Leave search"} =
               Enum.find(general.shortcuts, &("Esc" in &1.keys))
    end

    test "it documents \"v\" as the way out to GitHub" do
      general = Enum.find(Layouts.shortcut_groups(), &(&1.title == "General"))

      assert %{keys: ["v"], label: "Open on GitHub"} =
               Enum.find(general.shortcuts, &("v" in &1.keys))
    end

    test "it documents \"m\" as the inbox read toggle" do
      lists = Enum.find(Layouts.shortcut_groups(), &(&1.title == "Lists"))

      assert %{keys: ["m"], label: "Toggle read (inbox)"} =
               Enum.find(lists.shortcuts, &("m" in &1.keys))
    end

    test "it documents \"s\" as the inbox save toggle" do
      lists = Enum.find(Layouts.shortcut_groups(), &(&1.title == "Lists"))

      assert %{keys: ["s"], label: "Toggle save (inbox)"} =
               Enum.find(lists.shortcuts, &("s" in &1.keys))
    end

    test "it renders on a dead page too, where there is no socket", %{conn: conn} do
      html = conn |> get(~p"/changes") |> html_response(200)

      assert html =~ ~s(<dialog id="shortcuts")
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

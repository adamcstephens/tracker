defmodule TrackerWeb.LayoutsTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Tracker.Nixpkgs.Channel

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
      assert html =~ ~s(placeholder="Filter changes…")
      assert html =~ ~s(name="search")
    end

    test "renders a search input in the chrome on Packages", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/packages")

      assert html =~ ~r{app-header__row--bottom.*?action="/packages"}s
      assert html =~ ~s(placeholder="Filter packages…")
    end

    test "Channels page has no search slot", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/channels")

      # Channels has no search; the row should still render but without a form.
      refute html =~ ~r{app-header__row--bottom.*?<form[^>]*method="get"}s
    end

    test "Changes search form preserves base_ref via hidden input", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/changes?base_ref=master")

      assert html =~
               ~r{app-header__row--bottom.*?<input[^>]*type="hidden"[^>]*name="base_ref"[^>]*value="master"}s
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

    test "Options search form preserves page via hidden input", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/options?page=3")

      [_top, bottom] = String.split(html, "app-header__row--bottom", parts: 2)
      [chrome_form, _rest] = String.split(bottom, "</form>", parts: 2)

      assert chrome_form =~ ~r{<input[^>]*type="hidden"[^>]*name="page"[^>]*value="3"}
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

  describe "mobile bottom tab bar" do
    test "renders a fixed bottom nav with five tab links", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/changes")

      assert html =~ ~s(class="app-mobile-tabs")
      assert html =~ ~s(aria-label="Sections")

      # Five primary mobile tabs.
      for label <- ~w(Pkgs Chans Changes Options More) do
        assert html =~ ~r{class="app-mobile-tab[^"]*"[^>]*>\s*#{label}}
      end
    end

    test "active mobile tab matches current section", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/changes")

      # The Changes mobile tab should have aria-current=page.
      assert html =~
               ~r{class="app-mobile-tab[^"]*is-active[^"]*"[^>]*aria-current="page"[^>]*>\s*Changes}
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

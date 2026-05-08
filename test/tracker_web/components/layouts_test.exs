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

defmodule TrackerWeb.ModuleLive.IndexTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup do
    for name <- ["services.nginx", "services.postgresql", "programs.git"] do
      Tracker.Nixpkgs.Module
      |> Ash.Changeset.for_create(:bulk_upsert, %{display_name: name})
      |> Ash.create!()
    end

    :ok
  end

  test "renders module list", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/modules")

    assert html =~ "services.nginx"
    assert html =~ "services.postgresql"
    assert html =~ "programs.git"
  end

  test "search filters modules", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/modules?search=nginx")

    assert html =~ "services.nginx"
    refute html =~ "programs.git"
  end

  test "shows fallback notice when lens is set to 'all'", %{conn: conn} do
    Tracker.Nixpkgs.Channel.create!(%{
      name: "nixos-25.11",
      display_name: "NixOS 25.11",
      branch: "release-25.11",
      status: :active,
      is_stable: true
    })

    {:ok, view, _html} = live(conn, ~p"/modules")

    send(view.pid, {:set_lens, "all", ""})
    html = render(view)

    assert html =~ "Modules requires a specific channel"
    assert html =~ "Showing nixos-25.11"
  end

  test "does not show fallback notice for specific channel", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/modules")

    refute html =~ "Modules requires a specific channel"
  end
end

defmodule TrackerWeb.ModuleLive.IndexTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup do
    for {decl, name} <- [
          {"services.nginx", "services.nginx"},
          {"services.postgresql", "services.postgresql"},
          {"programs.git", "programs.git"}
        ] do
      Tracker.Nixpkgs.Module
      |> Ash.Changeset.for_create(:bulk_upsert, %{declaration: decl, display_name: name})
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
end

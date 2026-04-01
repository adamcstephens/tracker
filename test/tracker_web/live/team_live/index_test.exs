defmodule TrackerWeb.TeamLive.IndexTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup do
    for {short_name, scope} <- [
          {"python", "Python ecosystem"},
          {"rust", "Rust ecosystem"},
          {"gnome", "GNOME desktop"}
        ] do
      Tracker.Nixpkgs.Team
      |> Ash.Changeset.for_create(:bulk_upsert, %{short_name: short_name, scope: scope})
      |> Ash.create!()
    end

    :ok
  end

  test "renders team list with names and scopes", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/teams")

    assert html =~ "python"
    assert html =~ "Python ecosystem"
    assert html =~ "rust"
    assert html =~ "gnome"
  end

  test "search filters teams", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/teams?search=python")

    assert html =~ "python"
    refute html =~ "gnome"
  end
end

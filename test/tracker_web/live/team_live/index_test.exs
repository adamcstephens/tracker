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

  test "renders teams as shared row-list link rows with the scope as a sublabel", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/teams")

    document = Floki.parse_document!(html)
    [list] = Floki.find(document, "#teams")

    assert Floki.attribute(list, "class") == ["row-list row-list--reserve-sublabel"]
    assert Floki.attribute(list, "phx-update") == ["stream"]
    assert Floki.find(document, "table") == []

    row =
      list
      |> Floki.find("li")
      |> Enum.find(&(Floki.find(&1, ~s(a[href="/teams/python"])) != []))

    assert Floki.find(row, "a.row-link") != []
    assert Floki.text(Floki.find(row, ".row-sublabel")) =~ "Python ecosystem"
    assert Floki.attribute(row, "id") != []
  end

  test "search filters teams", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/teams?search=python")

    assert html =~ "python"
    refute html =~ "gnome"
  end

  test "fuzzy search tolerates typos on short_name", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/teams?search=rusty")

    assert html =~ "Rust ecosystem"
    refute html =~ "GNOME desktop"
  end

  test "fuzzy search tolerates typos on scope", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/teams?search=Pythen")

    assert html =~ "Python ecosystem"
    refute html =~ "GNOME desktop"
  end
end

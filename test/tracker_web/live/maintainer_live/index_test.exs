defmodule TrackerWeb.MaintainerLive.IndexTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup do
    for {github_id, github} <- [
          {1001, "alice"},
          {1002, "bob"},
          {1003, "charlie"}
        ] do
      Tracker.Nixpkgs.Maintainer
      |> Ash.Changeset.for_create(:bulk_upsert, %{
        github_id: github_id,
        github: github
      })
      |> Ash.create!()
    end

    :ok
  end

  test "renders maintainer list with github handles", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/maintainers")

    assert html =~ "alice"
    assert html =~ "bob"
  end

  test "renders maintainers as shared row-list link rows", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/maintainers")

    document = Floki.parse_document!(html)
    [list] = Floki.find(document, "#maintainers")

    assert Floki.attribute(list, "class") == ["row-list"]
    assert Floki.find(list, ~s(a.row-link[href="/maintainers/alice"])) != []
    assert Floki.find(document, "table") == []
  end

  test "the list streams so pagination and search can replace it", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/maintainers")

    document = Floki.parse_document!(html)
    [list] = Floki.find(document, "#maintainers")

    assert Floki.attribute(list, "phx-update") == ["stream"]
    # Stream children must carry their own DOM ids
    assert list |> Floki.find("li") |> Enum.all?(&(Floki.attribute(&1, "id") != []))
  end

  test "search filters by github handle", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/maintainers?search=charlie")

    assert html =~ "charlie"
    refute html =~ "alice"
  end

  test "fuzzy search tolerates github handle typos", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/maintainers?search=chartlie")

    assert html =~ "charlie"
    refute html =~ "bob"
  end
end

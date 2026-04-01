defmodule TrackerWeb.MaintainerLive.IndexTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup do
    for {github_id, name, github} <- [
          {1001, "Alice", "alice"},
          {1002, "Bob", "bob"},
          {1003, "Charlie", "charlie"}
        ] do
      Tracker.Nixpkgs.Maintainer
      |> Ash.Changeset.for_create(:bulk_upsert, %{
        github_id: github_id,
        name: name,
        github: github
      })
      |> Ash.create!()
    end

    :ok
  end

  test "renders maintainer list with names and github handles", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/maintainers")

    assert html =~ "Alice"
    assert html =~ "Bob"
    assert html =~ "alice"
    assert html =~ "bob"
  end

  test "search filters by name", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/maintainers?search=alice")

    assert html =~ "Alice"
    refute html =~ "Bob"
  end

  test "search filters by github handle", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/maintainers?search=charlie")

    assert html =~ "Charlie"
    refute html =~ "Alice"
  end
end

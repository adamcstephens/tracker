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

  test "search filters by github handle", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/maintainers?search=charlie")

    assert html =~ "charlie"
    refute html =~ "alice"
  end
end

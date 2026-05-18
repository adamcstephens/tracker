defmodule TrackerWeb.MaintainerLive.ShowTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup do
    maintainer =
      Tracker.Nixpkgs.Maintainer
      |> Ash.Changeset.for_create(:bulk_upsert, %{
        github_id: 2001,
        github: "testmaint"
      })
      |> Ash.create!()

    pkg_map =
      Tracker.Nixpkgs.Package.bulk_upsert_all([
        %{attribute: "maint-pkg-one"},
        %{attribute: "maint-pkg-two"}
      ])

    for {_attr, pkg_id} <- pkg_map do
      Tracker.Nixpkgs.PackageMaintainer
      |> Ash.Changeset.for_create(:load, %{
        maintainer_id: maintainer.id,
        package_id: pkg_id
      })
      |> Ash.create!()
    end

    %{maintainer: maintainer}
  end

  test "renders maintainer details", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/maintainers/testmaint")

    assert html =~ "testmaint"
  end

  test "shows maintained packages", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/maintainers/testmaint")

    assert html =~ "maint-pkg-one"
    assert html =~ "maint-pkg-two"
  end

  test "package_search filters packages", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/maintainers/testmaint?package_search=one")

    assert html =~ "maint-pkg-one"
    refute html =~ "maint-pkg-two"
  end

  test "global search param does not filter the inner packages table", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/maintainers/testmaint?search=one")

    assert html =~ "maint-pkg-one"
    assert html =~ "maint-pkg-two"
  end
end

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

  test "packages render as shared row-list link rows", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/maintainers/testmaint")

    document = Floki.parse_document!(html)
    [list] = Floki.find(document, "#maintainer-packages")

    assert Floki.attribute(list, "class") == ["row-list"]
    assert Floki.find(list, ~s(a.row-link[href="/packages/maint-pkg-one"])) != []
    assert Floki.find(document, "table") == []
  end

  test "teams render as shared row-list link rows", %{conn: conn} do
    team =
      Tracker.Nixpkgs.Team
      |> Ash.Changeset.for_create(:bulk_upsert, %{
        short_name: "python",
        scope: "Python ecosystem"
      })
      |> Ash.create!()

    maintainer = Tracker.Nixpkgs.Maintainer.get_by_github!("testmaint")

    Tracker.Nixpkgs.TeamMember
    |> Ash.Changeset.for_create(:load, %{team_id: team.id, maintainer_id: maintainer.id})
    |> Ash.create!()

    {:ok, _view, html} = live(conn, ~p"/maintainers/testmaint")

    document = Floki.parse_document!(html)
    [list] = Floki.find(document, "#maintainer-teams")

    assert Floki.find(list, ~s(a.row-link[href="/teams/python"])) != []
    assert Floki.text(list) =~ "Python ecosystem"
  end

  test "recent changes render as shared row-list rows instead of a raw table", %{conn: conn} do
    Tracker.Nixpkgs.Change
    |> Ash.Changeset.for_create(:bulk_upsert, %{
      number: 4242,
      title: "python3Packages.numpy: 2.0.0 -> 2.1.0",
      state: :merged,
      url: "https://github.com/NixOS/nixpkgs/pull/4242",
      base_ref: "master",
      author_github_id: 2001,
      merged_at: ~U[2026-04-01 10:00:00Z],
      gh_updated_at: ~U[2026-04-01 10:00:00Z]
    })
    |> Ash.create!()

    {:ok, _view, html} = live(conn, ~p"/maintainers/testmaint")

    document = Floki.parse_document!(html)
    [list] = Floki.find(document, "#maintainer-recent-changes")

    assert Floki.find(list, ~s(a.row-link[href="/changes/4242"])) != []
    assert Floki.text(list) =~ "python3Packages.numpy"
    assert Floki.text(list) =~ "author"
    assert Floki.text(list) =~ "2026-04-01"
    # The inline-styled truncation went with the table
    refute html =~ "text-overflow: ellipsis"
  end

  test "package search form submits via GET for no-JS fallback", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/maintainers/testmaint")

    [form] =
      html
      |> Floki.parse_document!()
      |> Floki.find("form#maintainer-package-search")

    assert Floki.attribute(form, "method") == ["get"]
    assert Floki.attribute(form, "action") == ["/maintainers/testmaint"]
  end
end

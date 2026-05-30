defmodule TrackerWeb.TeamLive.ShowTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup do
    team =
      Tracker.Nixpkgs.Team
      |> Ash.Changeset.for_create(:bulk_upsert, %{
        short_name: "teamshow",
        scope: "Test team scope"
      })
      |> Ash.create!()

    maintainer =
      Tracker.Nixpkgs.Maintainer
      |> Ash.Changeset.for_create(:bulk_upsert, %{
        github_id: 3001,
        github: "teammember"
      })
      |> Ash.create!()

    Tracker.Nixpkgs.TeamMember
    |> Ash.Changeset.for_create(:load, %{team_id: team.id, maintainer_id: maintainer.id})
    |> Ash.create!()

    pkg_map = Tracker.Nixpkgs.Package.bulk_upsert_all([%{attribute: "team-pkg"}])

    for {_attr, pkg_id} <- pkg_map do
      Tracker.Nixpkgs.PackageTeam
      |> Ash.Changeset.for_create(:load, %{team_id: team.id, package_id: pkg_id})
      |> Ash.create!()
    end

    %{team: team}
  end

  test "renders team details with scope", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/teams/teamshow")

    assert html =~ "teamshow"
    assert html =~ "Test team scope"
  end

  test "shows team members", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/teams/teamshow")

    assert html =~ "teammember"
  end

  test "shows team packages", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/teams/teamshow")

    assert html =~ "team-pkg"
  end

  test "package search form submits via GET for no-JS fallback", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/teams/teamshow")

    [form] =
      html
      |> Floki.parse_document!()
      |> Floki.find("form#team-package-search")

    assert Floki.attribute(form, "method") == ["get"]
    assert Floki.attribute(form, "action") == ["/teams/teamshow"]
  end
end

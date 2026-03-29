defmodule TrackerWeb.PackageLive.ShowTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup do
    channel_revision =
      Ash.create!(Tracker.Nixpkgs.ChannelRevision, %{
        channel: "nixos-unstable",
        revision: "abc123def456789"
      })

    package =
      Tracker.Nixpkgs.Package
      |> Ash.Changeset.for_create(:create, %{attribute: "hello"})
      |> Ash.create!()

    Tracker.Nixpkgs.PackageRevision
    |> Ash.Changeset.for_create(:load, %{
      version: "2.12.1",
      package_id: package.id,
      channel_revision_id: channel_revision.id
    })
    |> Ash.create!()

    %{package: package, channel_revision: channel_revision}
  end

  test "displays package attribute as heading", %{conn: conn, package: package} do
    {:ok, _view, html} = live(conn, ~p"/packages/#{package.id}")

    assert html =~ "hello"
  end

  test "displays revision with version and channel", %{conn: conn, package: package} do
    {:ok, _view, html} = live(conn, ~p"/packages/#{package.id}")

    assert html =~ "2.12.1"
    assert html =~ "nixos-unstable"
  end

  test "displays truncated revision hash linked to github", %{conn: conn, package: package} do
    {:ok, _view, html} = live(conn, ~p"/packages/#{package.id}")

    assert html =~ "abc123d"
    assert html =~ "https://github.com/NixOS/nixpkgs/commit/abc123def456789"
  end

  test "shows empty state when no revisions", %{conn: conn} do
    empty_package =
      Tracker.Nixpkgs.Package
      |> Ash.Changeset.for_create(:create, %{attribute: "empty-pkg"})
      |> Ash.create!()

    {:ok, _view, html} = live(conn, ~p"/packages/#{empty_package.id}")

    assert html =~ "No revisions found"
  end
end

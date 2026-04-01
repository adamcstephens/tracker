defmodule TrackerWeb.ChannelLive.DiffTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup do
    cr1 =
      Ash.create!(Tracker.Nixpkgs.ChannelRevision, %{
        channel: "nixos-unstable",
        revision: "dif111aaa222333",
        released_at: ~U[2026-03-01 10:00:00Z]
      })

    cr2 =
      Ash.create!(Tracker.Nixpkgs.ChannelRevision, %{
        channel: "nixos-unstable",
        revision: "dif222bbb444555",
        released_at: ~U[2026-03-15 10:00:00Z],
        previous_channel_revision_id: cr1.id
      })

    pkg_hello =
      Tracker.Nixpkgs.Package
      |> Ash.Changeset.for_create(:create, %{attribute: "diff-hello"})
      |> Ash.create!()

    pkg_world =
      Tracker.Nixpkgs.Package
      |> Ash.Changeset.for_create(:create, %{attribute: "diff-world"})
      |> Ash.create!()

    pkg_gone =
      Tracker.Nixpkgs.Package
      |> Ash.Changeset.for_create(:create, %{attribute: "diff-gone-pkg"})
      |> Ash.create!()

    # hello: version changed between revisions
    Tracker.Nixpkgs.PackageRevision.load!(%{
      version: "2.12.1",
      package_id: pkg_hello.id,
      channel_revision_id: cr1.id
    })

    Tracker.Nixpkgs.PackageRevision.load!(%{
      version: "2.13.0",
      package_id: pkg_hello.id,
      channel_revision_id: cr2.id
    })

    # world: same version in both (unchanged)
    Tracker.Nixpkgs.PackageRevision.load!(%{
      version: "1.0.0",
      package_id: pkg_world.id,
      channel_revision_id: cr1.id
    })

    Tracker.Nixpkgs.PackageRevision.load!(%{
      version: "1.0.0",
      package_id: pkg_world.id,
      channel_revision_id: cr2.id
    })

    # gone-pkg: only in cr1, removed in cr2
    Tracker.Nixpkgs.PackageRevision.load!(%{
      version: "0.5.0",
      package_id: pkg_gone.id,
      channel_revision_id: cr1.id
    })

    # Event: world was added in cr2
    Tracker.Nixpkgs.PackageEvent
    |> Ash.Changeset.for_create(:create, %{
      type: :added,
      package_id: pkg_world.id,
      channel_revision_id: cr2.id
    })
    |> Ash.create!()

    %{
      cr1: cr1,
      cr2: cr2,
      pkg_hello: pkg_hello,
      pkg_world: pkg_world,
      pkg_gone: pkg_gone
    }
  end

  test "renders diff page with short hashes", %{conn: conn, cr1: cr1, cr2: cr2} do
    {:ok, _view, html} =
      live(conn, ~p"/channels/nixos-unstable/diff/#{cr1.revision}/#{cr2.revision}")

    assert html =~ String.slice(cr1.revision, 0, 7)
    assert html =~ String.slice(cr2.revision, 0, 7)
  end

  test "renders diff page with full hashes", %{conn: conn, cr1: cr1, cr2: cr2} do
    {:ok, _view, html} =
      live(conn, ~p"/channels/nixos-unstable/diff/#{cr1.revision}/#{cr2.revision}")

    assert html =~ String.slice(cr1.revision, 0, 7)
    assert html =~ String.slice(cr2.revision, 0, 7)
  end

  test "shows package events between revisions", %{conn: conn, cr1: cr1, cr2: cr2} do
    {:ok, _view, html} =
      live(conn, ~p"/channels/nixos-unstable/diff/#{cr1.revision}/#{cr2.revision}")

    assert html =~ "diff-world"
    assert html =~ "added"
  end

  test "shows package version changes", %{conn: conn, cr1: cr1, cr2: cr2} do
    {:ok, _view, html} =
      live(conn, ~p"/channels/nixos-unstable/diff/#{cr1.revision}/#{cr2.revision}")

    # diff-hello changed from 2.12.1 to 2.13.0
    assert html =~ "diff-hello"
    assert html =~ "2.12.1"
    assert html =~ "2.13.0"
  end

  test "shows removed packages in diff", %{conn: conn, cr1: cr1, cr2: cr2} do
    {:ok, _view, html} =
      live(conn, ~p"/channels/nixos-unstable/diff/#{cr1.revision}/#{cr2.revision}")

    assert html =~ "diff-gone-pkg"
  end

  test "does not show unchanged packages in version changes", %{conn: conn, cr1: cr1, cr2: cr2} do
    {:ok, view, _html} =
      live(conn, ~p"/channels/nixos-unstable/diff/#{cr1.revision}/#{cr2.revision}")

    # diff-world is 1.0.0 in both revisions - it should not appear in the version changes table
    version_changes_html = view |> element("section:last-of-type table") |> render()
    refute version_changes_html =~ ">diff-world<"
  end

  test "returns 404 for unknown revision", %{conn: conn, cr1: cr1} do
    assert_raise Ash.Error.Invalid, fn ->
      live(conn, ~p"/channels/nixos-unstable/diff/#{cr1.revision}/fffffff")
    end
  end

  test "links to github compare", %{conn: conn, cr1: cr1, cr2: cr2} do
    {:ok, _view, html} =
      live(conn, ~p"/channels/nixos-unstable/diff/#{cr1.revision}/#{cr2.revision}")

    assert html =~
             "https://github.com/NixOS/nixpkgs/compare/#{cr1.revision}...#{cr2.revision}"
  end

  test "links back to channel page", %{conn: conn, cr1: cr1, cr2: cr2} do
    {:ok, _view, html} =
      live(conn, ~p"/channels/nixos-unstable/diff/#{cr1.revision}/#{cr2.revision}")

    assert html =~ ~s|href="/channels/nixos-unstable"|
  end
end

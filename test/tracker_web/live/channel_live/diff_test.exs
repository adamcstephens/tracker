defmodule TrackerWeb.ChannelLive.DiffTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Tracker.Fixtures

  setup do
    channel = Fixtures.channel!("nixos-unstable")

    cr1 =
      Fixtures.channel_revision!(channel, %{
        revision: "dif111aaa222333",
        released_at: ~U[2026-03-01 10:00:00Z]
      })

    cr2 =
      Fixtures.channel_revision!(channel, %{
        revision: "dif222bbb444555",
        released_at: ~U[2026-03-15 10:00:00Z],
        previous_channel_revision_id: cr1.id
      })

    hello = Fixtures.package!("diff-hello")
    added = Fixtures.package!("diff-added-pkg")
    gone = Fixtures.package!("diff-gone-pkg")
    stay = Fixtures.package!("diff-stay")

    Fixtures.apply_package_revision!(cr1, [
      {hello, "2.12.1"},
      {gone, "0.5.0"},
      {stay, "1.0.0"}
    ])

    Fixtures.apply_package_revision!(cr2, [
      {hello, "2.13.0"},
      {added, "1.0.0"},
      {stay, "1.0.0"}
    ])

    Fixtures.remove_package!(cr2, gone)

    opt_changed = Fixtures.option!("diff.opt.changed")
    opt_added = Fixtures.option!("diff.opt.added")

    Fixtures.apply_option_revision!(cr1, [
      {opt_changed, %{description: "Old description.", type: "boolean", default: "false"}}
    ])

    Fixtures.apply_option_revision!(cr2, [
      {opt_changed, %{description: "New description.", type: "boolean", default: "false"}},
      {opt_added, %{description: "Just added.", type: "boolean", default: "false"}}
    ])

    %{cr1: cr1, cr2: cr2}
  end

  test "renders diff page with short hashes", %{conn: conn, cr1: cr1, cr2: cr2} do
    {:ok, _view, html} =
      live(conn, ~p"/channels/nixos-unstable/diff/#{cr1.revision}/#{cr2.revision}")

    assert html =~ String.slice(cr1.revision, 0, 7)
    assert html =~ String.slice(cr2.revision, 0, 7)
  end

  test "shows package events between revisions", %{conn: conn, cr1: cr1, cr2: cr2} do
    {:ok, _view, html} =
      live(conn, ~p"/channels/nixos-unstable/diff/#{cr1.revision}/#{cr2.revision}")

    assert html =~ "diff-added-pkg"
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

    # diff-stay is 1.0.0 in both revisions - it should not appear in version changes
    version_changes_html = view |> element("section:last-of-type table") |> render()
    refute version_changes_html =~ ">diff-stay<"
  end

  test "returns 404 for unknown revision", %{conn: conn, cr1: cr1} do
    assert_raise Ash.Error.Invalid, fn ->
      live(conn, ~p"/channels/nixos-unstable/diff/#{cr1.revision}/fffffff")
    end
  end

  test "shows option events between revisions", %{conn: conn, cr1: cr1, cr2: cr2} do
    {:ok, _view, html} =
      live(conn, ~p"/channels/nixos-unstable/diff/#{cr1.revision}/#{cr2.revision}")

    assert html =~ "diff.opt.added"
    assert html =~ ~s|href="/options/diff.opt.added"|
  end

  test "shows option metadata changes between revisions", %{conn: conn, cr1: cr1, cr2: cr2} do
    {:ok, _view, html} =
      live(conn, ~p"/channels/nixos-unstable/diff/#{cr1.revision}/#{cr2.revision}")

    assert html =~ "diff.opt.changed"
    assert html =~ "Old description."
    assert html =~ "New description."
  end

  test "does not list unchanged options in metadata changes", %{conn: conn, cr1: cr1, cr2: cr2} do
    {:ok, _view, html} =
      live(conn, ~p"/channels/nixos-unstable/diff/#{cr1.revision}/#{cr2.revision}")

    # opt_added exists only in cr2; it should appear in option events,
    # not the metadata-changes section.
    refute html =~ ~r/Option Metadata.*diff\.opt\.added/s
  end

  test "shows diff summary counts", %{conn: conn, cr1: cr1, cr2: cr2} do
    {:ok, _view, html} =
      live(conn, ~p"/channels/nixos-unstable/diff/#{cr1.revision}/#{cr2.revision}")

    [summary] = html |> Floki.parse_document!() |> Floki.find("dl.diff-summary")
    text = summary |> Floki.text() |> String.replace(~r/\s+/, " ") |> String.trim()

    assert text =~ "Packages: 1 added"
    assert text =~ "1 version change"
    assert text =~ "Options: 1 added"
    assert text =~ "1 metadata change"
  end

  test "links to github compare", %{conn: conn, cr1: cr1, cr2: cr2} do
    {:ok, _view, html} =
      live(conn, ~p"/channels/nixos-unstable/diff/#{cr1.revision}/#{cr2.revision}")

    assert html =~
             "https://github.com/NixOS/nixpkgs/compare/#{cr1.revision}...#{cr2.revision}"
  end
end

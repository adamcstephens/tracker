defmodule TrackerWeb.ChannelLive.RevisionShowTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Tracker.Fixtures

  setup do
    channel_unstable = Fixtures.channel!("nixos-unstable")
    channel_stable = Fixtures.channel!("nixos-24.11")

    cr1 =
      Fixtures.channel_revision!(channel_unstable, %{
        revision: "rev111aaa222333",
        released_at: ~U[2026-03-01 10:00:00Z]
      })

    cr2 =
      Fixtures.channel_revision!(channel_unstable, %{
        revision: "rev222bbb444555",
        released_at: ~U[2026-03-15 10:00:00Z],
        previous_channel_revision_id: cr1.id
      })

    cr_no_prev =
      Fixtures.channel_revision!(channel_stable, %{
        revision: "rev333fff666777",
        released_at: ~U[2026-03-20 10:00:00Z]
      })

    hello = Fixtures.package!("revshow-hello")
    added = Fixtures.package!("revshow-added")

    # hello: version changed between cr1 and cr2; added: appears only in cr2.
    Fixtures.apply_package_revision!(cr1, [{hello, "2.12.1"}])
    Fixtures.apply_package_revision!(cr2, [{hello, "2.13.0"}, {added, "1.0.0"}])

    opt_changed = Fixtures.option!("revshow.opt.changed")
    opt_added = Fixtures.option!("revshow.opt.added")

    Fixtures.apply_option_revision!(cr1, [
      {opt_changed, %{description: "Revshow old description.", type: "boolean", default: "false"}}
    ])

    Fixtures.apply_option_revision!(cr2, [
      {opt_changed,
       %{description: "Revshow new description.", type: "boolean", default: "false"}},
      {opt_added, %{description: "Revshow added option.", type: "boolean", default: "false"}}
    ])

    %{cr1: cr1, cr2: cr2, cr_no_prev: cr_no_prev}
  end

  test "renders revision metadata", %{conn: conn, cr2: cr2} do
    {:ok, _view, html} =
      live(conn, ~p"/channels/nixos-unstable/revisions/#{short(cr2)}")

    assert html =~ "nixos-unstable"
    assert html =~ String.slice(cr2.revision, 0, 7)
    assert html =~ "2026-03-15"
  end

  test "renders with full hash", %{conn: conn, cr2: cr2} do
    {:ok, _view, html} =
      live(conn, ~p"/channels/nixos-unstable/revisions/#{cr2.revision}")

    assert html =~ String.slice(cr2.revision, 0, 7)
  end

  test "shows result when present", %{conn: conn, cr2: cr2} do
    Ash.update!(Ash.Changeset.for_update(cr2, :record_result, %{result: :success}))

    {:ok, _view, html} =
      live(conn, ~p"/channels/nixos-unstable/revisions/#{short(cr2)}")

    assert html =~ "Success"
  end

  test "shows diff from previous revision", %{conn: conn, cr2: cr2} do
    {:ok, _view, html} =
      live(conn, ~p"/channels/nixos-unstable/revisions/#{short(cr2)}")

    # Should show version changes from cr1 -> cr2
    assert html =~ "revshow-hello"
    assert html =~ "2.12.1"
    assert html =~ "2.13.0"
  end

  test "shows package events from previous revision", %{conn: conn, cr2: cr2} do
    {:ok, _view, html} =
      live(conn, ~p"/channels/nixos-unstable/revisions/#{short(cr2)}")

    assert html =~ "added"
  end

  test "shows option events from previous revision", %{conn: conn, cr2: cr2} do
    {:ok, _view, html} =
      live(conn, ~p"/channels/nixos-unstable/revisions/#{short(cr2)}")

    assert html =~ "revshow.opt.added"
    assert html =~ ~s|href="/options/revshow.opt.added"|
  end

  test "shows option metadata changes from previous revision", %{conn: conn, cr2: cr2} do
    {:ok, _view, html} =
      live(conn, ~p"/channels/nixos-unstable/revisions/#{short(cr2)}")

    assert html =~ "revshow.opt.changed"
    assert html =~ "Revshow old description."
    assert html =~ "Revshow new description."
  end

  test "shows diff summary counts when previous revision exists", %{conn: conn, cr2: cr2} do
    {:ok, _view, html} =
      live(conn, ~p"/channels/nixos-unstable/revisions/#{short(cr2)}")

    [summary] = html |> Floki.parse_document!() |> Floki.find("dl.diff-summary")
    text = summary |> Floki.text() |> String.replace(~r/\s+/, " ") |> String.trim()

    assert text =~ "Packages: 1 added"
    assert text =~ "0 removed"
    assert text =~ "1 version change"
    assert text =~ "Options: 1 added"
    assert text =~ "1 metadata change"
  end

  test "does not render diff summary when no previous revision", %{conn: conn, cr_no_prev: cr} do
    {:ok, _view, html} =
      live(conn, ~p"/channels/nixos-24.11/revisions/#{short(cr)}")

    assert html |> Floki.parse_document!() |> Floki.find("dl.diff-summary") == []
  end

  test "shows no-diff message when no previous revision", %{conn: conn, cr_no_prev: cr} do
    {:ok, _view, html} =
      live(conn, ~p"/channels/nixos-24.11/revisions/#{short(cr)}")

    assert html =~ "first known revision"
  end

  test "links to GitHub commit", %{conn: conn, cr2: cr2} do
    {:ok, _view, html} =
      live(conn, ~p"/channels/nixos-unstable/revisions/#{short(cr2)}")

    assert html =~ "https://github.com/NixOS/nixpkgs/commit/#{cr2.revision}"
  end

  test "updates result when the revision result is recorded", %{
    conn: conn,
    cr2: cr2
  } do
    {:ok, view, html} =
      live(conn, ~p"/channels/nixos-unstable/revisions/#{cr2.revision}")

    # Initially no result
    refute html =~ "Success"
    assert html =~ "Result: -"

    Tracker.Nixpkgs.ChannelRevision.record_result!(cr2, %{result: :success})

    html = render(view)
    assert html =~ "Result: Success"
  end

  test "returns error for unknown revision", %{conn: conn} do
    assert_raise Ash.Error.Invalid, fn ->
      live(conn, ~p"/channels/nixos-unstable/revisions/fffffff")
    end
  end

  defp short(cr), do: String.slice(cr.revision, 0, 7)
end

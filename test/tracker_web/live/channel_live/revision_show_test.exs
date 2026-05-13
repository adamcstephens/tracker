defmodule TrackerWeb.ChannelLive.RevisionShowTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Tracker.Nixpkgs.Channel

  setup do
    channel_unstable =
      Channel.create!(%{
        name: "nixos-unstable",
        display_name: "NixOS Unstable",
        status: :active,
        is_stable: false
      })

    channel_stable =
      Channel.create!(%{
        name: "nixos-24.11",
        display_name: "NixOS 24.11",
        status: :active,
        is_stable: true
      })

    cr1 =
      Ash.create!(Tracker.Nixpkgs.ChannelRevision, %{
        channel_id: channel_unstable.id,
        revision: "rev111aaa222333",
        released_at: ~U[2026-03-01 10:00:00Z]
      })

    cr2 =
      Ash.create!(Tracker.Nixpkgs.ChannelRevision, %{
        channel_id: channel_unstable.id,
        revision: "rev222bbb444555",
        released_at: ~U[2026-03-15 10:00:00Z],
        previous_channel_revision_id: cr1.id
      })

    cr_no_prev =
      Ash.create!(Tracker.Nixpkgs.ChannelRevision, %{
        channel_id: channel_stable.id,
        revision: "rev333fff666777",
        released_at: ~U[2026-03-20 10:00:00Z]
      })

    pkg_hello =
      Tracker.Nixpkgs.Package
      |> Ash.Changeset.for_create(:create, %{attribute: "revshow-hello"})
      |> Ash.create!()

    # hello: version changed between cr1 and cr2
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

    # Event: hello was added in cr2
    Tracker.Nixpkgs.PackageEvent
    |> Ash.Changeset.for_create(:create, %{
      type: :added,
      package_id: pkg_hello.id,
      channel_revision_id: cr2.id
    })
    |> Ash.create!()

    %{"revshow.opt.changed" => opt_changed_id, "revshow.opt.added" => opt_added_id} =
      Tracker.Nixpkgs.Option.bulk_upsert_all([
        %{name: "revshow.opt.changed"},
        %{name: "revshow.opt.added"}
      ])

    # opt_changed: present in both cr1 and cr2 with a different description
    Tracker.Nixpkgs.OptionRevision.load!(%{
      option_id: opt_changed_id,
      channel_revision_id: cr1.id,
      description: "Revshow old description.",
      type: "boolean",
      default: "false",
      example: nil,
      read_only: false
    })

    Tracker.Nixpkgs.OptionRevision.load!(%{
      option_id: opt_changed_id,
      channel_revision_id: cr2.id,
      description: "Revshow new description.",
      type: "boolean",
      default: "false",
      example: nil,
      read_only: false
    })

    # opt_added: only in cr2
    Tracker.Nixpkgs.OptionRevision.load!(%{
      option_id: opt_added_id,
      channel_revision_id: cr2.id,
      description: "Revshow added option.",
      type: "boolean",
      default: "false",
      example: nil,
      read_only: false
    })

    Tracker.Nixpkgs.OptionEvent
    |> Ash.Changeset.for_create(:create, %{
      type: :added,
      option_id: opt_added_id,
      channel_revision_id: cr2.id
    })
    |> Ash.create!()

    %{cr1: cr1, cr2: cr2, cr_no_prev: cr_no_prev, pkg_hello: pkg_hello}
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

  test "updates result when channel_revision_completed is broadcast", %{
    conn: conn,
    cr2: cr2
  } do
    {:ok, view, html} =
      live(conn, ~p"/channels/nixos-unstable/revisions/#{cr2.revision}")

    # Initially no result
    refute html =~ "Success"
    assert html =~ "Result: -"

    # Simulate finalize setting the result
    Ash.update!(Ash.Changeset.for_update(cr2, :record_result, %{result: :success}))

    Phoenix.PubSub.broadcast(
      Tracker.PubSub,
      "channel_revisions:nixos-unstable",
      {:channel_revision_completed, %{channel_name: "nixos-unstable", revision: cr2.revision}}
    )

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

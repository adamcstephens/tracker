defmodule TrackerWeb.ChannelLive.ShowTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup do
    cr1 =
      Ash.create!(Tracker.Nixpkgs.ChannelRevision, %{
        channel: "nixos-unstable",
        revision: "aaa111bbb222333",
        released_at: ~U[2026-03-01 10:00:00Z]
      })

    cr2 =
      Ash.create!(Tracker.Nixpkgs.ChannelRevision, %{
        channel: "nixos-unstable",
        revision: "ccc333ddd444555",
        released_at: ~U[2026-03-15 10:00:00Z],
        previous_channel_revision_id: cr1.id
      })

    %{cr1: cr1, cr2: cr2}
  end

  test "updates when a new revision is broadcast", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/channels/nixos-unstable")

    refute html =~ "fff999"

    Ash.create!(Tracker.Nixpkgs.ChannelRevision, %{
      channel: "nixos-unstable",
      revision: "fff999ggg000111",
      released_at: ~U[2026-03-20 10:00:00Z]
    })

    Phoenix.PubSub.broadcast(
      Tracker.PubSub,
      "channel_revisions:nixos-unstable",
      {:channel_revision_completed, %{channel: "nixos-unstable", revision: "fff999ggg000111"}}
    )

    html = render(view)
    assert html =~ "fff999g"
  end

  test "renders checkboxes for revision selection", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/channels/nixos-unstable")

    assert html =~ ~s|type="checkbox"|
  end

  test "shows diff link when two revisions are checked", %{conn: conn, cr1: cr1, cr2: cr2} do
    {:ok, view, _html} = live(conn, ~p"/channels/nixos-unstable")

    html =
      view
      |> element(~s|input[type="checkbox"][phx-value-revision="#{cr1.revision}"]|)
      |> render_click()

    refute html =~ "Show diff"

    html =
      view
      |> element(~s|input[type="checkbox"][phx-value-revision="#{cr2.revision}"]|)
      |> render_click()

    assert html =~ "Show diff"
    assert html =~ ~p"/channels/diff/#{cr1.revision}/#{cr2.revision}"
  end

  test "unchecking a revision hides diff link", %{conn: conn, cr1: cr1, cr2: cr2} do
    {:ok, view, _html} = live(conn, ~p"/channels/nixos-unstable")

    view
    |> element(~s|input[type="checkbox"][phx-value-revision="#{cr1.revision}"]|)
    |> render_click()

    view
    |> element(~s|input[type="checkbox"][phx-value-revision="#{cr2.revision}"]|)
    |> render_click()

    html =
      view
      |> element(~s|input[type="checkbox"][phx-value-revision="#{cr1.revision}"]|)
      |> render_click()

    refute html =~ "Show diff"
  end

  test "checking a third revision drops the oldest", %{conn: conn, cr1: cr1, cr2: cr2} do
    cr3 =
      Ash.create!(Tracker.Nixpkgs.ChannelRevision, %{
        channel: "nixos-unstable",
        revision: "eee555fff666777",
        released_at: ~U[2026-03-20 10:00:00Z]
      })

    {:ok, view, _html} = live(conn, ~p"/channels/nixos-unstable")

    view
    |> element(~s|input[type="checkbox"][phx-value-revision="#{cr1.revision}"]|)
    |> render_click()

    view
    |> element(~s|input[type="checkbox"][phx-value-revision="#{cr2.revision}"]|)
    |> render_click()

    html =
      view
      |> element(~s|input[type="checkbox"][phx-value-revision="#{cr3.revision}"]|)
      |> render_click()

    assert html =~ "Show diff"
    assert html =~ ~p"/channels/diff/#{cr2.revision}/#{cr3.revision}"
    refute html =~ ~s|checked="checked" phx-value-revision="#{cr1.revision}"|
  end
end

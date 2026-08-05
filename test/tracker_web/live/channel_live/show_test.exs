defmodule TrackerWeb.ChannelLive.ShowTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Tracker.Nixpkgs.Channel

  setup do
    channel =
      Channel.create!(%{
        name: "nixos-unstable",
        display_name: "NixOS Unstable",
        status: :active,
        is_stable: false
      })

    cr1 =
      Ash.create!(Tracker.Nixpkgs.ChannelRevision, %{
        channel_id: channel.id,
        revision: "shw111aaa222333",
        released_at: ~U[2026-03-01 10:00:00Z]
      })

    cr2 =
      Ash.create!(Tracker.Nixpkgs.ChannelRevision, %{
        channel_id: channel.id,
        revision: "shw222bbb444555",
        released_at: ~U[2026-03-15 10:00:00Z],
        previous_channel_revision_id: cr1.id
      })

    %{cr1: cr1, cr2: cr2, channel: channel}
  end

  test "updates when a revision result is recorded", %{conn: conn, channel: channel} do
    {:ok, view, html} = live(conn, ~p"/channels/nixos-unstable")

    refute html =~ "fff999"

    cr =
      Ash.create!(Tracker.Nixpkgs.ChannelRevision, %{
        channel_id: channel.id,
        revision: "fff999ggg000111",
        released_at: ~U[2026-03-20 10:00:00Z]
      })

    Tracker.Nixpkgs.ChannelRevision.record_result!(cr, %{result: :success})

    html = render(view)
    assert html =~ "fff999g"
  end

  test "updates when a new revision is created", %{conn: conn, channel: channel} do
    {:ok, view, html} = live(conn, ~p"/channels/nixos-unstable")

    refute html =~ "ccc888"

    Ash.create!(Tracker.Nixpkgs.ChannelRevision, %{
      channel_id: channel.id,
      revision: "ccc888ddd999eee",
      released_at: ~U[2026-03-22 10:00:00Z]
    })

    html = render(view)
    assert html =~ "ccc888d"
  end

  test "the revisions list carries a section header with its count", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/channels/nixos-unstable")

    assert has_element?(view, ".section-header h2", "Revisions")
    assert has_element?(view, ".section-header .n", "2")
  end

  test "renders checkboxes for revision selection", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/channels/nixos-unstable")

    assert html =~ ~s|type="checkbox"|
  end

  test "renders revisions as shared row-list rows", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/channels/nixos-unstable")

    assert html =~ ~s(class="row-list)
    assert html =~ ~s(class="row-line")
    assert html =~ ~s(href="/channels/nixos-unstable/revisions/shw222bbb444555")
    assert html =~ "2026-03-15 10:00"
  end

  test "rows are not whole-row links, so the compare checkbox stays clickable", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/channels/nixos-unstable")

    refute html =~ "row-link"
  end

  test "the result column is gone", %{conn: conn, channel: channel} do
    cr =
      Ash.create!(Tracker.Nixpkgs.ChannelRevision, %{
        channel_id: channel.id,
        revision: "res111aaa222333",
        released_at: ~U[2026-03-25 10:00:00Z]
      })

    Tracker.Nixpkgs.ChannelRevision.record_result!(cr, %{result: :success})

    {:ok, _view, html} = live(conn, ~p"/channels/nixos-unstable")

    assert html =~ "res111a"
    refute html =~ "Success"
  end

  test "column sorting is gone", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/channels/nixos-unstable")

    refute html =~ "phx-value-field"
    refute html =~ "<table"
  end

  test "revisions are listed newest first", %{conn: conn, cr1: cr1, cr2: cr2} do
    {:ok, _view, html} = live(conn, ~p"/channels/nixos-unstable")

    {newest, _} = :binary.match(html, String.slice(cr2.revision, 0, 7))
    {oldest, _} = :binary.match(html, String.slice(cr1.revision, 0, 7))

    assert newest < oldest
  end

  test "revisions form submits via GET to the diff endpoint", %{conn: conn, cr1: cr1} do
    {:ok, _view, html} = live(conn, ~p"/channels/nixos-unstable")

    document = Floki.parse_document!(html)
    [form] = Floki.find(document, "form#revisions-form")

    assert Floki.attribute(form, "method") == ["get"]
    assert Floki.attribute(form, "action") == ["/channels/nixos-unstable/diff"]

    checkboxes = Floki.find(form, ~s|input[type="checkbox"][name="compare[]"]|)
    assert Enum.any?(checkboxes, &(Floki.attribute(&1, "value") == [cr1.revision]))

    assert Floki.find(form, "button[type=submit]") != []
  end

  test "pagination links page through the revisions", %{conn: conn, channel: channel} do
    for n <- 1..20 do
      Ash.create!(Tracker.Nixpkgs.ChannelRevision, %{
        channel_id: channel.id,
        revision: "pag#{String.pad_leading("#{n}", 3, "0")}aaa222333",
        released_at: DateTime.add(~U[2026-04-01 10:00:00Z], n, :day)
      })
    end

    {:ok, view, html} = live(conn, ~p"/channels/nixos-unstable")

    assert html =~ "Page 1 of 2"
    # Newest first, so the oldest seeded revision can only be on page 2
    refute html =~ "shw111a"

    html = view |> element(~s(a[href="/channels/nixos-unstable?page=2"])) |> render_click()

    assert html =~ "shw111a"
  end

  test "renders a Build problem badge in the header when hydra reports failure",
       %{conn: conn, channel: channel} do
    {:ok, _} =
      Channel.update_hydra_status(channel, %{
        hydra_build_failed?: true,
        hydra_project: "nixos",
        hydra_jobset: "unstable",
        hydra_exported_job: "tested"
      })

    {:ok, _view, html} = live(conn, ~p"/channels/nixos-unstable")

    assert html =~ "Build problem"
    assert html =~ "https://hydra.nixos.org/jobset/nixos/unstable"
  end

  test "does not render Build problem badge by default", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/channels/nixos-unstable")
    refute html =~ "Build problem"
  end
end

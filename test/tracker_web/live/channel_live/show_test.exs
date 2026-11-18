defmodule TrackerWeb.ChannelLive.ShowTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Tracker.Nixpkgs.Channel

  setup do
    channel =
      Channel.create!(%{
        name: "nixos-chanshow",
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

  test "header exposes metadata actions and real channel status", %{conn: conn, channel: channel} do
    Channel.update_status!(channel, %{status: :pre_release})
    Channel.update_hydra_status!(channel, %{hydra_project: "custom", hydra_jobset: "actual"})
    {:ok, view, _} = live(conn, ~p"/channels/nixos-chanshow")

    assert has_element?(view, ".channel-show__title h1", channel.name)
    assert has_element?(view, ".channel-show__status", "Beta")

    assert has_element?(
             view,
             "#hydra-jobset[href='https://hydra.nixos.org/jobset/custom/actual']"
           )

    assert has_element?(view, "#feed-link[phx-hook='CopyLink']", "Atom feed")
    refute has_element?(view, ".channel-show", "Channel revisions")
    refute has_element?(view, ".channel-show", "Rolling")
  end

  test "hydra action requires both metadata fields", %{conn: conn, channel: channel} do
    Channel.update_hydra_status!(channel, %{hydra_project: "custom"})
    {:ok, view, _} = live(conn, ~p"/channels/nixos-chanshow")
    refute has_element?(view, "#hydra-jobset")
  end

  test "retired status suppresses build problem", %{conn: conn, channel: channel} do
    Channel.update_status!(channel, %{status: :retired})
    Channel.update_hydra_status!(channel, %{hydra_build_failed?: true})
    {:ok, view, _} = live(conn, ~p"/channels/nixos-chanshow")
    assert has_element?(view, ".channel-show__status", "Retired")
    refute has_element?(view, ".channel-show__status", "Build problem")
  end

  test "selection controls expose native revision metadata", %{conn: conn, cr1: cr1, cr2: cr2} do
    {:ok, view, _} = live(conn, ~p"/channels/nixos-chanshow")
    assert has_element?(view, "#compare-selected[disabled]")
    assert has_element?(view, "#clear-selection[type=button]")
    assert has_element?(view, "#revision-#{cr2.id} .channel-show__latest", "Latest")
    refute has_element?(view, "#revision-#{cr1.id} .channel-show__latest")
    assert has_element?(view, "#select-#{cr1.id}[data-released-at='2026-03-01T10:00:00Z']")
  end

  test "updates when a revision result is recorded", %{conn: conn, channel: channel} do
    {:ok, view, html} = live(conn, ~p"/channels/nixos-chanshow")

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
    {:ok, view, html} = live(conn, ~p"/channels/nixos-chanshow")

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
    {:ok, view, _html} = live(conn, ~p"/channels/nixos-chanshow")

    assert has_element?(view, ".section-header h2", "Revisions")
    assert has_element?(view, ".section-header .n", "2")
  end

  test "renders checkboxes for revision selection", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/channels/nixos-chanshow")

    assert html =~ ~s|type="checkbox"|
  end

  test "renders revisions as shared row-list rows", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/channels/nixos-chanshow")

    assert has_element?(view, "#revisions.row-list")
    assert has_element?(view, "#revisions .row-line--leading")

    assert [_] =
             html
             |> Floki.parse_document!()
             |> Floki.find(~s(a[href^="/channels/nixos-chanshow/revisions/shw222bbb444555"]))

    assert html =~ "2026-03-15 10:00 UTC"
  end

  test "rows are not whole-row links, so the compare checkbox stays clickable", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/channels/nixos-chanshow")

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

    {:ok, _view, html} = live(conn, ~p"/channels/nixos-chanshow")

    assert html =~ "res111a"
    refute html =~ "Success"
  end

  test "column sorting is gone", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/channels/nixos-chanshow")

    refute html =~ "phx-value-field"
    refute html =~ "<table"
  end

  test "revisions are listed newest first", %{conn: conn, cr1: cr1, cr2: cr2} do
    {:ok, _view, html} = live(conn, ~p"/channels/nixos-chanshow")

    {newest, _} = :binary.match(html, String.slice(cr2.revision, 0, 7))
    {oldest, _} = :binary.match(html, String.slice(cr1.revision, 0, 7))

    assert newest < oldest
  end

  test "revisions form submits via GET to the diff endpoint", %{conn: conn, cr1: cr1} do
    {:ok, _view, html} = live(conn, ~p"/channels/nixos-chanshow")

    document = Floki.parse_document!(html)
    [form] = Floki.find(document, "form#revisions-form")

    assert Floki.attribute(form, "method") == ["get"]
    assert Floki.attribute(form, "action") == ["/channels/nixos-chanshow/diff"]

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

    {:ok, view, html} = live(conn, ~p"/channels/nixos-chanshow")

    assert html =~ "Page 1 of 2"
    # Newest first, so the oldest seeded revision can only be on page 2
    refute html =~ "shw111a"

    html = view |> element(~s(a[href*="page=2"])) |> render_click()

    assert html =~ "shw111a"
    refute has_element?(view, ".channel-show__latest")
  end

  test "empty channels retain their empty state", %{conn: conn} do
    Channel.create!(%{name: "empty-show", display_name: "Empty", status: :active})
    {:ok, view, _} = live(conn, ~p"/channels/empty-show")
    assert has_element?(view, ".channel-show p", "No revisions found.")
    refute has_element?(view, "#revisions-form")
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

    {:ok, _view, html} = live(conn, ~p"/channels/nixos-chanshow")

    assert html =~ "Build problem"
    assert html =~ "https://hydra.nixos.org/jobset/nixos/unstable"
  end

  test "does not render Build problem badge by default", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/channels/nixos-chanshow")
    refute html =~ "Build problem"
  end
end

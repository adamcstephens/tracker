defmodule TrackerWeb.ChangeLive.IndexTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup do
    Tracker.Nixpkgs.Change.bulk_upsert_all([
      %{
        number: 5001,
        title: "feat: add new-pkg",
        state: :merged,
        author: "alice",
        base_ref: "master",
        url: "https://github.com/NixOS/nixpkgs/pull/5001",
        merged_at: ~U[2026-04-01 12:00:00Z]
      },
      %{
        number: 5002,
        title: "[Backport release-25.11] fix: something",
        state: :merged,
        author: "bob",
        base_ref: "release-25.11",
        url: "https://github.com/NixOS/nixpkgs/pull/5002",
        merged_at: ~U[2026-04-01 13:00:00Z]
      }
    ])

    :ok
  end

  test "renders changes list with PR details", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/changes")

    assert html =~ "5001"
    assert html =~ "feat: add new-pkg"
    assert html =~ "master"
    assert html =~ "5002"
    assert html =~ "release-25.11"
  end

  test "does not render an author column", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/changes")

    refute html =~ "alice"
    refute html =~ "Author"
  end

  test "shows a status pill, marking closed PRs", %{conn: conn} do
    Tracker.Nixpkgs.Change.bulk_upsert_all([
      %{
        number: 5004,
        title: "fix: abandoned work",
        state: :closed,
        author: "dave",
        base_ref: "master",
        url: "https://github.com/NixOS/nixpkgs/pull/5004",
        closed_at: ~U[2026-04-02 09:00:00Z]
      }
    ])

    {:ok, _view, html} = live(conn, ~p"/changes")
    doc = Floki.parse_document!(html)

    assert Floki.find(doc, "td .pill-closed") != []
    assert Floki.find(doc, "td .pill-merged") != []
  end

  test "sorting by status", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/changes")

    view |> element("th[phx-value-field=state]") |> render_click()
    assert_patched(view, ~p"/changes?sort_by=state&sort_dir=asc")
  end

  test "search filters by title", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/changes")

    html =
      view
      |> element("form.app-search")
      |> render_change(%{"search" => "Backport"})

    assert html =~ "5002"
    refute html =~ "5001"
  end

  test "search filters by author", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/changes")

    html =
      view
      |> element("form.app-search")
      |> render_change(%{"search" => "alice"})

    assert html =~ "5001"
    refute html =~ "5002"
  end

  test "fuzzy search tolerates title typos", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/changes")

    html =
      view
      |> element("form.app-search")
      |> render_change(%{"search" => "Backporrt"})

    assert html =~ "5002"
    refute html =~ "5001"
  end

  test "fuzzy search tolerates author typos", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/changes")

    html =
      view
      |> element("form.app-search")
      |> render_change(%{"search" => "aalice"})

    assert html =~ "5001"
    refute html =~ "5002"
  end

  test "search filters by PR number", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/changes")

    html =
      view
      |> element("form.app-search")
      |> render_change(%{"search" => "5002"})

    assert html =~ "Backport"
    refute html =~ "5001"
  end

  test "base_ref dropdown filters by branch", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/changes?base_ref=release-25.11")

    assert html =~ "5002"
    refute html =~ "5001"
  end

  test "base_ref filter form has a submit button for no-JS fallback", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/changes")

    [form] =
      html
      |> Floki.parse_document!()
      |> Floki.find("form#change-base-ref-filter")

    assert Floki.attribute(form, "method") == ["get"]
    assert Floki.find(form, "button[type=submit]") != []
  end

  test "pagination links keep the base_ref filter", %{conn: conn} do
    Tracker.Nixpkgs.Change.bulk_upsert_all(
      for n <- 6001..6020 do
        %{
          number: n,
          title: "chore: filler #{n}",
          state: :merged,
          author: "eve",
          base_ref: "release-25.11",
          url: "https://github.com/NixOS/nixpkgs/pull/#{n}"
        }
      end
    )

    {:ok, _view, html} = live(conn, ~p"/changes?base_ref=release-25.11")

    [next] =
      html
      |> Floki.parse_document!()
      |> Floki.find("nav a.pagination-button:last-of-type")

    assert query_params(next) == %{"base_ref" => "release-25.11", "page" => "2"}
  end

  test "sort links keep the base_ref filter", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/changes?base_ref=release-25.11")

    [title_link] =
      html
      |> Floki.parse_document!()
      |> Floki.find("th[phx-value-field=title] a")

    assert query_params(title_link) == %{
             "base_ref" => "release-25.11",
             "sort_by" => "title",
             "sort_dir" => "asc"
           }
  end

  defp query_params(link) do
    [href] = Floki.attribute(link, "href")
    href |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
  end

  test "sorting by title ascending", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/changes")

    view |> element("th[phx-value-field=title]") |> render_click()
    assert_patched(view, ~p"/changes?sort_by=title&sort_dir=asc")
  end

  test "updates when a Change is updated via notifier", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/changes")

    refute html =~ "5003"

    Tracker.Nixpkgs.Change.bulk_upsert_all([
      %{
        number: 5003,
        title: "feat: broadcast test",
        state: :merged,
        author: "charlie",
        base_ref: "master",
        url: "https://github.com/NixOS/nixpkgs/pull/5003"
      }
    ])

    {:ok, change} = Tracker.Nixpkgs.Change.get_by_number(5001)
    Tracker.Nixpkgs.Change.update_processing_status!(change, %{processing_status: :processed})

    html = render(view)
    assert html =~ "5003"
    assert html =~ "broadcast test"
  end
end

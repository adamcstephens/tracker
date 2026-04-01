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
    assert html =~ "alice"
    assert html =~ "master"
    assert html =~ "5002"
    assert html =~ "bob"
    assert html =~ "release-25.11"
  end

  test "search filters by title", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/changes")

    html =
      view
      |> element("#change-filters")
      |> render_change(%{"search" => "Backport", "base_ref" => ""})

    assert html =~ "5002"
    refute html =~ "5001"
  end

  test "search filters by author", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/changes")

    html =
      view
      |> element("#change-filters")
      |> render_change(%{"search" => "alice", "base_ref" => ""})

    assert html =~ "5001"
    refute html =~ "5002"
  end

  test "base_ref dropdown filters by branch", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/changes?base_ref=release-25.11")

    assert html =~ "5002"
    refute html =~ "5001"
  end

  test "sorting by title ascending", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/changes")

    view |> element("th[phx-value-field=title]") |> render_click()
    assert_patched(view, ~p"/changes?sort_by=title&sort_dir=asc")
  end
end

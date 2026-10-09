defmodule TrackerWeb.ChannelLive.RevisionComparisonTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  alias Tracker.Fixtures

  setup do
    channel = Fixtures.channel!("comparison-paging")

    from =
      Fixtures.channel_revision!(channel, %{
        revision: "aaaaaaa111111",
        released_at: ~U[2026-03-01 10:00:00Z]
      })

    to =
      Fixtures.channel_revision!(channel, %{
        revision: "bbbbbbb222222",
        released_at: ~U[2026-03-02 10:00:00Z],
        previous_channel_revision_id: from.id
      })

    packages =
      for(
        n <- 1..16,
        do: Fixtures.package!("compare-#{String.pad_leading(to_string(n), 2, "0")}")
      ) ++ [Fixtures.package!("compare-seventeen")]

    added = Fixtures.package!("compare-added")
    Fixtures.apply_package_revision!(from, Enum.map(packages, &{&1, "1"}))
    Fixtures.apply_package_revision!(to, Enum.map(packages, &{&1, "2"}) ++ [{added, "3"}])

    options =
      for n <- 1..16,
          do: Fixtures.option!("compare.option#{String.pad_leading(to_string(n), 2, "0")}")

    common_description = String.duplicate("Shared introduction. ", 20)

    Fixtures.apply_option_revision!(
      from,
      Enum.map(
        options,
        &{&1, %{description: common_description <> "changed-old", type: "boolean"}}
      )
    )

    Fixtures.apply_option_revision!(
      to,
      Enum.map(
        options,
        &{&1, %{description: common_description <> "changed-new", type: "string"}}
      )
    )

    %{from: from, to: to}
  end

  for entry <- [:show, :diff] do
    @entry entry
    test "#{entry} independently pages unique packages and grouped options", %{
      conn: conn,
      from: from,
      to: to
    } do
      path = comparison_path(@entry, from, to)
      {:ok, view, _} = live(conn, path)
      assert has_element?(view, "#packages tbody tr", "compare-01")
      refute has_element?(view, "#packages tbody tr", "compare-16")
      assert has_element?(view, "#pagination-packages", "Page 1 of 2")
      assert has_element?(view, "#pagination-options", "Page 1 of 2")

      view |> element("#pagination-options a", "→") |> render_click()
      assert has_element?(view, "#options", "compare.option16")
      refute has_element?(view, "#options", "compare.option01")
      assert has_element?(view, "#packages tbody tr", "compare-01")

      view |> element("#pagination-packages a", "→") |> render_click()
      assert has_element?(view, "#packages tbody tr", "compare-16")
      refute has_element?(view, "#packages tbody tr", "compare-01")
      assert has_element?(view, "#options", "compare.option16")
      assert has_element?(view, "#pagination-packages [aria-disabled=true]")
    end

    test "#{entry} searches and filters before pagination", %{conn: conn, from: from, to: to} do
      {:ok, view, _} = live(conn, comparison_path(@entry, from, to) <> "?page=2&option_page=2")
      view |> element("a[data-change=added]") |> render_click()
      assert has_element?(view, "#packages tbody tr", "compare-added")
      assert has_element?(view, "a[data-change=added][aria-pressed=true]")
      assert has_element?(view, "a[data-change=all][aria-pressed=false]")
      refute has_element?(view, "#packages tbody tr", "compare-16")
      refute has_element?(view, "#pagination-packages")
      assert has_element?(view, "#options", "compare.option16")

      view |> element("a[data-change=all]") |> render_click()
      view |> form("#page-search", %{search: "seventeen"}) |> render_change()
      assert has_element?(view, "#packages tbody tr", "compare-seventeen")
      refute has_element?(view, "#packages tbody tr", "compare-added")
      refute has_element?(view, "#pagination-packages")
    end

    test "#{entry} previews the changed portion of long metadata and discloses full values", %{
      conn: conn,
      from: from,
      to: to
    } do
      {:ok, view, _html} = live(conn, comparison_path(@entry, from, to))

      assert has_element?(
               view,
               ".comparison-values:not(.comparison-full-values) p",
               "changed-old"
             )

      assert has_element?(
               view,
               ".comparison-values:not(.comparison-full-values) p",
               "changed-new"
             )

      assert has_element?(
               view,
               ".comparison-full-values pre",
               String.duplicate("Shared introduction. ", 20)
             )
    end

    test "#{entry} endpoint navigation retains a different channel lens", %{
      conn: conn,
      from: from,
      to: to
    } do
      Fixtures.channel!("comparison-lens")

      {:ok, view, html} =
        live(conn, comparison_path(@entry, from, to) <> "?channel=comparison-lens")

      assert has_element?(
               view,
               "a[href='/channels/comparison-paging/revisions/#{from.revision}?channel=comparison-lens']"
             )

      assert has_element?(
               view,
               "a[href='/channels/comparison-paging/revisions/#{to.revision}?channel=comparison-lens']"
             )

      assert has_element?(
               view,
               "a[href='https://github.com/NixOS/nixpkgs/compare/#{from.revision}...#{to.revision}']"
             )

      refute html =~ "Result:"
      assert has_element?(view, "a", "Use as lens")
    end
  end

  defp comparison_path(:show, _from, to),
    do: "/channels/comparison-paging/revisions/#{to.revision}"

  defp comparison_path(:diff, from, to),
    do: "/channels/comparison-paging/diff/#{from.revision}/#{to.revision}"
end

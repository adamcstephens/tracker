defmodule TrackerWeb.PaginationTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Component, only: [sigil_H: 2]

  alias TrackerWeb.Pagination

  describe "controls/1" do
    test "renders page info and prev/next links when total_pages > 1" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <Pagination.controls
          total_pages={3}
          current_page={2}
          has_prev_page?={true}
          has_next_page?={true}
          prev_path="/items?page=1"
          next_path="/items?page=3"
          anchor="items"
        />
        """)

      assert html =~ "Page 2 of 3"
      assert html =~ ~s(href="/items?page=1#items")
      assert html =~ ~s(href="/items?page=3#items")
    end

    test "hidden when total_pages <= 1" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <Pagination.controls
          total_pages={1}
          current_page={1}
          prev_path="/items?page=1"
          next_path="/items?page=2"
          anchor="items"
        />
        """)

      refute html =~ "Page"
      refute html =~ "href"
    end

    test "renders page number without total when total_pages is nil" do
      assigns = %{total_pages: nil}

      html =
        rendered_to_string(~H"""
        <Pagination.controls
          total_pages={@total_pages}
          current_page={2}
          has_prev_page?={true}
          has_next_page?={true}
          prev_path="/items?page=1"
          next_path="/items?page=3"
          anchor="items"
        />
        """)

      assert html =~ "Page 2"
      refute html =~ "Page 2 of"
    end

    test "hidden when total_pages is nil and no neighboring pages" do
      assigns = %{total_pages: nil}

      html =
        rendered_to_string(~H"""
        <Pagination.controls
          total_pages={@total_pages}
          current_page={1}
          has_prev_page?={false}
          has_next_page?={false}
          prev_path="/items?page=1"
          next_path="/items?page=2"
          anchor="items"
        />
        """)

      refute html =~ "Page"
      refute html =~ "href"
    end

    test "disabled prev/next render as non-link spans" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <Pagination.controls
          total_pages={2}
          current_page={1}
          has_prev_page?={false}
          has_next_page?={true}
          prev_path="/items?page=1"
          next_path="/items?page=2"
          anchor="items"
        />
        """)

      assert html =~ ~s(href="/items?page=2#items")
      refute html =~ ~s(href="/items?page=1)
      assert html =~ ~s(aria-disabled="true")
    end

    test "carries the anchor hook so JS navigation lands on the list too" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <Pagination.controls
          total_pages={3}
          current_page={2}
          has_prev_page?={true}
          has_next_page?={true}
          prev_path="/items?page=1"
          next_path="/items?page=3"
          anchor="items"
        />
        """)

      assert html =~ ~s(phx-hook="PageAnchor")
      assert html =~ ~s(data-anchor="items")
      assert html =~ ~s(data-page="2")
      assert html =~ ~s(id="pagination-items")
    end
  end
end

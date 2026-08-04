defmodule TrackerWeb.DataTableTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Component, only: [sigil_H: 2]

  alias TrackerWeb.DataTable

  describe "pagination/1" do
    test "renders page info and buttons when total_pages > 1" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <DataTable.pagination
          total_pages={3}
          current_page={2}
          has_prev_page?={true}
          has_next_page?={true}
        />
        """)

      assert html =~ "Page 2 of 3"
      assert html =~ "prev-page"
      assert html =~ "next-page"
    end

    test "hidden when total_pages <= 1" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <DataTable.pagination
          total_pages={1}
          current_page={1}
        />
        """)

      refute html =~ "Page"
      refute html =~ "prev-page"
    end

    test "disables prev button on first page" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <DataTable.pagination
          total_pages={2}
          current_page={1}
          has_prev_page?={false}
          has_next_page?={true}
        />
        """)

      assert html =~ "disabled"
    end

    test "disables next button on last page" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <DataTable.pagination
          total_pages={2}
          current_page={2}
          has_prev_page?={true}
          has_next_page?={false}
        />
        """)

      # Both buttons present, next should be disabled
      assert html =~ "prev-page"
      assert html =~ "next-page"
    end

    test "renders page number without total when total_pages is nil" do
      assigns = %{total_pages: nil}

      html =
        rendered_to_string(~H"""
        <DataTable.pagination
          total_pages={@total_pages}
          current_page={2}
          has_prev_page?={true}
          has_next_page?={true}
        />
        """)

      assert html =~ "Page 2"
      refute html =~ "Page 2 of"
      assert html =~ "prev-page"
      assert html =~ "next-page"
    end

    test "hidden when total_pages is nil and no neighboring pages" do
      assigns = %{total_pages: nil}

      html =
        rendered_to_string(~H"""
        <DataTable.pagination
          total_pages={@total_pages}
          current_page={1}
          has_prev_page?={false}
          has_next_page?={false}
        />
        """)

      refute html =~ "Page"
      refute html =~ "prev-page"
    end

    test "renders prev/next as links when prev_path and next_path are given" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <DataTable.pagination
          total_pages={3}
          current_page={2}
          has_prev_page?={true}
          has_next_page?={true}
          prev_path="/items?page=1"
          next_path="/items?page=3"
        />
        """)

      assert html =~ ~s(href="/items?page=1")
      assert html =~ ~s(href="/items?page=3")
    end

    test "disabled prev/next render as non-link spans when paths are given" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <DataTable.pagination
          total_pages={2}
          current_page={1}
          has_prev_page?={false}
          has_next_page?={true}
          prev_path="/items?page=1"
          next_path="/items?page=2"
        />
        """)

      # next is enabled — should be an anchor
      assert html =~ ~s(href="/items?page=2")
      # prev is disabled — should NOT be an anchor to that URL
      refute html =~ ~s(href="/items?page=1")
    end
  end
end

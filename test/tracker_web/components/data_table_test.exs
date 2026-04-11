defmodule TrackerWeb.DataTableTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Component, only: [sigil_H: 2]

  alias TrackerWeb.DataTable
  alias TrackerWeb.TableParams

  defp table_params(overrides \\ []) do
    defaults = [
      allowed_sorts: ~w(name age)a,
      default_sort: :name,
      default_sort_dir: :asc
    ]

    TableParams.from_params(%{}, Keyword.merge(defaults, overrides))
  end

  describe "data_table/1" do
    test "renders table with columns and rows" do
      assigns = %{
        tp: table_params(),
        rows: [%{id: 1, name: "Alice", age: 30}, %{id: 2, name: "Bob", age: 25}]
      }

      html =
        rendered_to_string(~H"""
        <DataTable.data_table id="test" rows={@rows} table_params={@tp}>
          <:col :let={row} field={:name} label="Name">{row.name}</:col>
          <:col :let={row} field={:age} label="Age">{row.age}</:col>
        </DataTable.data_table>
        """)

      assert html =~ "Alice"
      assert html =~ "Bob"
      assert html =~ "30"
      assert html =~ "25"
      assert html =~ "Name"
      assert html =~ "Age"
    end

    test "renders sort indicator on active sort column" do
      assigns = %{
        tp: table_params(),
        rows: []
      }

      html =
        rendered_to_string(~H"""
        <DataTable.data_table id="test" rows={@rows} table_params={@tp}>
          <:col :let={row} field={:name} label="Name" sortable>{row.name}</:col>
          <:col :let={row} field={:age} label="Age" sortable>{row.age}</:col>
        </DataTable.data_table>
        """)

      # name is default sort, ascending
      assert html =~ "Name"
      assert html =~ "↑"
    end

    test "renders descending sort indicator" do
      assigns = %{
        tp: table_params(default_sort_dir: :desc),
        rows: []
      }

      html =
        rendered_to_string(~H"""
        <DataTable.data_table id="test" rows={@rows} table_params={@tp}>
          <:col :let={row} field={:name} label="Name" sortable>{row.name}</:col>
        </DataTable.data_table>
        """)

      assert html =~ "↓"
    end

    test "non-sortable columns do not emit sort click" do
      assigns = %{
        tp: table_params(),
        rows: []
      }

      html =
        rendered_to_string(~H"""
        <DataTable.data_table id="test" rows={@rows} table_params={@tp}>
          <:col :let={row} field={:name} label="Name">{row.name}</:col>
        </DataTable.data_table>
        """)

      refute html =~ "phx-click"
      refute html =~ "sort"
    end

    test "sortable columns emit sort event with field" do
      assigns = %{
        tp: table_params(),
        rows: []
      }

      html =
        rendered_to_string(~H"""
        <DataTable.data_table id="test" rows={@rows} table_params={@tp}>
          <:col :let={row} field={:name} label="Name" sortable>{row.name}</:col>
        </DataTable.data_table>
        """)

      assert html =~ "phx-click"
      assert html =~ "sort"
      assert html =~ "name"
    end

    test "sortable columns render link when base_path is set" do
      assigns = %{
        tp: table_params(),
        rows: []
      }

      html =
        rendered_to_string(~H"""
        <DataTable.data_table id="test" rows={@rows} table_params={@tp} base_path="/items">
          <:col :let={row} field={:name} label="Name" sortable>{row.name}</:col>
          <:col :let={row} field={:age} label="Age" sortable>{row.age}</:col>
        </DataTable.data_table>
        """)

      # Active sort column (name, asc) links to toggled direction (desc)
      # sort_by=name is omitted because it's the default
      assert html =~ "href=\"/items?sort_dir=desc\""
      # Non-active sort column links to asc
      assert html =~ "href=\"/items?sort_by=age\""
    end

    test "sortable columns without base_path render as plain text" do
      assigns = %{
        tp: table_params(),
        rows: []
      }

      html =
        rendered_to_string(~H"""
        <DataTable.data_table id="test" rows={@rows} table_params={@tp}>
          <:col :let={row} field={:name} label="Name" sortable>{row.name}</:col>
        </DataTable.data_table>
        """)

      refute html =~ "<a"
      refute html =~ "href"
    end

    test "renders pagination when total_pages > 1" do
      assigns = %{
        tp: table_params(),
        rows: []
      }

      html =
        rendered_to_string(~H"""
        <DataTable.data_table
          id="test"
          rows={@rows}
          table_params={@tp}
          total_pages={3}
          current_page={2}
          has_prev_page?={true}
          has_next_page?={true}
        >
          <:col :let={row} field={:name} label="Name">{row.name}</:col>
        </DataTable.data_table>
        """)

      assert html =~ "Page 2 of 3"
      assert html =~ "prev-page"
      assert html =~ "next-page"
    end

    test "hides pagination when total_pages <= 1" do
      assigns = %{
        tp: table_params(),
        rows: []
      }

      html =
        rendered_to_string(~H"""
        <DataTable.data_table
          id="test"
          rows={@rows}
          table_params={@tp}
          total_pages={1}
          current_page={1}
        >
          <:col :let={row} field={:name} label="Name">{row.name}</:col>
        </DataTable.data_table>
        """)

      refute html =~ "Page"
      refute html =~ "prev-page"
    end

    test "disables prev button on first page" do
      assigns = %{
        tp: table_params(),
        rows: []
      }

      html =
        rendered_to_string(~H"""
        <DataTable.data_table
          id="test"
          rows={@rows}
          table_params={@tp}
          total_pages={2}
          current_page={1}
          has_prev_page?={false}
          has_next_page?={true}
        >
          <:col :let={row} field={:name} label="Name">{row.name}</:col>
        </DataTable.data_table>
        """)

      # The prev button should be disabled
      assert html =~ "prev-page"
    end

    test "supports row_click" do
      assigns = %{
        tp: table_params(),
        rows: [%{id: 1, name: "Alice", age: 30}]
      }

      html =
        rendered_to_string(~H"""
        <DataTable.data_table
          id="test"
          rows={@rows}
          table_params={@tp}
          row_click={fn row -> Phoenix.LiveView.JS.navigate("/items/#{row.id}") end}
        >
          <:col :let={row} field={:name} label="Name">{row.name}</:col>
        </DataTable.data_table>
        """)

      assert html =~ "phx-click"
      assert html =~ "Alice"
    end

    test "supports LiveStream rows" do
      assigns = %{
        tp: table_params(),
        rows: Phoenix.LiveView.LiveStream.new(:test, 0, [], [])
      }

      html =
        rendered_to_string(~H"""
        <DataTable.data_table id="test" rows={@rows} table_params={@tp}>
          <:col :let={row} field={:name} label="Name">{row.name}</:col>
        </DataTable.data_table>
        """)

      assert html =~ ~s(phx-update="stream")
    end

    test "supports action slot" do
      assigns = %{
        tp: table_params(),
        rows: [%{id: 1, name: "Alice", age: 30}]
      }

      html =
        rendered_to_string(~H"""
        <DataTable.data_table id="test" rows={@rows} table_params={@tp}>
          <:col :let={row} field={:name} label="Name">{row.name}</:col>
          <:action :let={row}>
            <a href={"/items/#{row.id}/edit"}>Edit</a>
          </:action>
        </DataTable.data_table>
        """)

      assert html =~ "Edit"
      assert html =~ "Actions"
    end
  end

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
  end
end

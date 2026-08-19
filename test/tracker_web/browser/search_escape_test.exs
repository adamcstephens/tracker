defmodule TrackerWeb.Browser.SearchEscapeTest do
  use TrackerWeb.PlaywrightCase,
    browser_pool: false,
    parameterize: [%{browser: :chromium}, %{browser: :firefox}]

  setup do
    channel!()
    for number <- 9001..9003, do: change!(number)

    :ok
  end

  defp read(conn, expression) do
    parent = self()
    evaluate(conn, expression, &send(parent, {:read, &1}))

    receive do
      {:read, value} -> value
    after
      0 -> flunk("evaluate/3 returned no value for #{expression}")
    end
  end

  defp changes_page(conn), do: visit(conn, ~p"/changes")

  defp searched_page(conn), do: visit(conn, ~p"/changes?search=change")

  test "/ focuses the search box and selects what is already in it", %{conn: conn} do
    conn = searched_page(conn)
    assert read(conn, ~s|document.getElementById("page-search-input").value|) == "change"

    press(conn, "body", "/")

    assert read(conn, ~s|document.activeElement.id|) == "page-search-input"

    assert read(conn, """
           let input = document.getElementById("page-search-input")
           input.selectionStart === 0 && input.selectionEnd === input.value.length
           """)
  end

  test "Escape leaves the search box on every engine", %{conn: conn} do
    conn = searched_page(conn)

    press(conn, "body", "/")
    assert read(conn, ~s|document.activeElement.id|) == "page-search-input"

    press(conn, "#page-search-input", "Escape")

    refute read(conn, ~s|document.activeElement.id|) == "page-search-input"
  end

  test "row navigation works immediately after Escape", %{conn: conn} do
    conn = changes_page(conn)

    press(conn, "body", "/")
    press(conn, "#page-search-input", "Escape")
    press(conn, "body", "j")

    assert read(conn, ~s|document.activeElement.matches(".row-line")|)
  end
end

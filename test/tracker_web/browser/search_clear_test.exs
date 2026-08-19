defmodule TrackerWeb.Browser.SearchClearTest do
  use TrackerWeb.PlaywrightCase

  setup do
    path = Path.join(System.tmp_dir!(), "dev-login-#{System.unique_integer([:positive])}.json")
    Application.put_env(:tracker, :dev_login_file, path)
    on_exit(fn -> File.rm(path) end)

    channel!()
    for number <- 9001..9003, do: change!(number)

    %{user: register_user!()}
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

  defp eventually(conn, expression, expected, attempts \\ 40) do
    actual = read(conn, expression)

    if actual == expected or attempts == 0 do
      actual
    else
      Process.sleep(50)
      eventually(conn, expression, expected, attempts - 1)
    end
  end

  defp searched(conn), do: visit(conn, ~p"/changes?search=change")

  defp signed_in(conn, user) do
    conn
    |> visit("/dev/login/#{Tracker.DevLogin.issue!(user.github_username)}")
    |> searched()
    |> assert_has(".phx-connected")
  end

  test "clearing over a full reload lands focus back in the search box", %{conn: conn} do
    conn = searched(conn)
    click(conn, "a.app-search__clear")

    assert eventually(conn, ~s|document.activeElement.id|, "page-search-input") ==
             "page-search-input"
  end

  test "clearing over a live navigation lands focus back in the search box", %{
    conn: conn,
    user: user
  } do
    conn = signed_in(conn, user)
    click(conn, "a.app-search__clear")

    assert eventually(conn, ~s|document.activeElement.id|, "page-search-input") ==
             "page-search-input"
  end

  test "a later navigation does not steal focus into the search box", %{conn: conn, user: user} do
    conn = signed_in(conn, user)
    click(conn, "a.app-search__clear")
    assert eventually(conn, ~s|document.activeElement.id|, "page-search-input")

    conn = visit(conn, ~p"/changes?search=change")

    assert eventually(conn, ~s|document.activeElement.id|, "") == ""
  end
end

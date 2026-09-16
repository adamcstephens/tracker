defmodule TrackerWeb.Browser.InboxCursorTest do
  use TrackerWeb.PlaywrightCase

  alias Tracker.Notifications.Notification

  @rows ~s|[...document.querySelectorAll("ul.row-list > li")].map((li) => li.id)|
  @cursor ~s|document.activeElement.closest("ul.row-list > li")?.id ?? ""|

  setup do
    path = Path.join(System.tmp_dir!(), "dev-login-#{System.unique_integer([:positive])}.json")
    Application.put_env(:tracker, :dev_login_file, path)
    on_exit(fn -> File.rm(path) end)

    channel!()
    user = register_user!()

    for minutes <- 1..3 do
      notification!(user, %{
        occurred_at: DateTime.add(DateTime.utc_now(:second), -minutes, :minute)
      })
    end

    %{user: user}
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

  defp connected(conn), do: assert_has(conn, ".phx-connected")

  defp inbox(conn, user) do
    conn
    |> visit("/dev/login/#{Tracker.DevLogin.issue!(user.github_username)}")
    |> visit(~p"/inbox")
    |> connected()
  end

  defp read_states(user) do
    Enum.map(Notification.for_user!(actor: user), &(&1.read_at != nil))
  end

  test "m drops the row and hands the cursor to the next one", %{conn: conn, user: user} do
    conn = inbox(conn, user)
    [_first, second, third] = read(conn, @rows)

    press(conn, "##{second} > .row-line", "m")

    assert eventually(conn, @cursor, third) == third
    refute_has(conn, "##{second}")
  end

  test "m on the last row hands the cursor back to the previous one", %{conn: conn, user: user} do
    conn = inbox(conn, user)
    [_first, second, third] = read(conn, @rows)

    press(conn, "##{third} > .row-line", "m")

    assert eventually(conn, @cursor, second) == second
    refute_has(conn, "##{third}")
  end

  test "under All the row stays and keeps the cursor", %{conn: conn, user: user} do
    conn = inbox(conn, user)
    click(conn, "#filter-all")
    [_first, second, _third] = read(conn, @rows)

    press(conn, "##{second} > .row-line", "m")

    assert_has(conn, "##{second} button[aria-label='Mark as unread']")
    assert eventually(conn, @cursor, second) == second
  end

  test "m is inert on a row carrying no read/unread button", %{conn: conn} do
    for number <- 9001..9003, do: change!(number)
    conn = visit(conn, ~p"/changes")

    [first | _] = read(conn, @rows)
    press(conn, "##{first} > .row-line", "m")

    assert read(conn, ~s|document.querySelectorAll("button[phx-click='toggle-read']").length|) ==
             0

    assert read(conn, @cursor) == first
  end

  test "the key and the mouse leave the same state behind", %{conn: conn, user: user} do
    conn = inbox(conn, user)
    click(conn, "#filter-all")
    [first, second, _third] = read(conn, @rows)

    press(conn, "##{first} > .row-line", "m")
    assert_has(conn, "##{first} button[aria-label='Mark as unread']")

    click(conn, "##{second} button[phx-click='toggle-read']")
    assert_has(conn, "##{second} button[aria-label='Mark as unread']")

    assert read_states(user) == [true, true, false]
  end

  test "s toggles the focused row's saved state without changing read state", %{
    conn: conn,
    user: user
  } do
    conn = inbox(conn, user)
    [_first, second, _third] = read(conn, @rows)
    row = "##{second}"
    id = second |> String.replace_prefix("notification-", "") |> String.to_integer()

    press(conn, "#{row} > .row-line", "s")

    assert_has(conn, "#{row} button[aria-label='Remove from saved'][aria-pressed='true']")
    assert eventually(conn, @cursor, second) == second

    assert %Notification{saved: true, read_at: nil} =
             Ash.get!(Notification, id, actor: user)

    press(conn, "#{row} > .row-line", "s")

    assert_has(conn, "#{row} button[aria-label='Save for later'][aria-pressed='false']")
    assert eventually(conn, @cursor, second) == second

    assert %Notification{saved: false, read_at: nil} =
             Ash.get!(Notification, id, actor: user)
  end

  test "Enter opens the highlighted notification", %{conn: conn, user: user} do
    pkg = package!()

    notification!(user, %{
      type: :package_added,
      package_id: pkg.id,
      occurred_at: DateTime.add(DateTime.utc_now(:second), 1, :minute)
    })

    conn = inbox(conn, user)

    press(conn, "body", "j")
    press(conn, ":focus", "Enter")

    assert_path(conn, "/packages/#{pkg.attribute}")
  end

  test "save controls are reachable by Tab and activate with Enter and Space without navigating",
       %{
         conn: conn,
         user: user
       } do
    pkg = package!()

    n =
      notification!(user, %{
        type: :package_added,
        package_id: pkg.id,
        occurred_at: DateTime.add(DateTime.utc_now(:second), 1, :minute)
      })

    conn = inbox(conn, user)
    row = "#notification-#{n.id}"
    save = "#{row} button[aria-label='Save for later'][aria-pressed='false']"
    remove = "#{row} button[aria-label='Remove from saved'][aria-pressed='true']"
    focused_save = ~s|document.activeElement.matches("#{save}")|

    press(conn, "#{row} > .row-line", "Tab")

    Enum.reduce_while(1..5, conn, fn _, conn ->
      if read(conn, focused_save) do
        {:halt, conn}
      else
        {:cont, press(conn, ":focus", "Tab")}
      end
    end)

    assert read(conn, focused_save)
    press(conn, ":focus", "Enter")

    assert_has(conn, remove)
    assert_path(conn, "/inbox")
    assert %Notification{saved: true, read_at: nil} = Ash.get!(Notification, n.id, actor: user)

    press(conn, remove, "Space")

    assert_has(conn, save)
    assert_path(conn, "/inbox")
    assert %Notification{saved: false, read_at: nil} = Ash.get!(Notification, n.id, actor: user)

    press(conn, "#{row} .row-label a", "Enter")
    assert_path(conn, "/packages/#{pkg.attribute}")
  end

  test "Saved keeps j and k navigation and m changes only read state without dropping the row", %{
    conn: conn,
    user: user
  } do
    for n <- Notification.for_user!(actor: user), do: Notification.save!(n, actor: user)

    conn = inbox(conn, user)
    click(conn, "#filter-saved")
    [first, second, third] = read(conn, @rows)

    press(conn, "##{first} > .row-line", "j")
    assert read(conn, @cursor) == second

    press(conn, "##{second} > .row-line", "k")
    assert read(conn, @cursor) == first

    press(conn, "##{first} > .row-line", "m")

    assert_has(conn, "##{first} button[aria-label='Mark as unread']")
    assert_has(conn, "##{first} button[aria-label='Remove from saved'][aria-pressed='true']")
    assert eventually(conn, @cursor, first) == first
    assert read(conn, @rows) == [first, second, third]
    assert read_states(user) == [true, false, false]
    assert Enum.all?(Notification.for_user!(actor: user), & &1.saved)
    assert_path(conn, "/inbox")

    press(conn, "##{first} > .row-line", "m")

    assert_has(conn, "##{first} button[aria-label='Mark as read']")
    assert_has(conn, "##{first} button[aria-label='Remove from saved'][aria-pressed='true']")
    assert eventually(conn, @cursor, first) == first
    assert read_states(user) == [false, false, false]
  end
end

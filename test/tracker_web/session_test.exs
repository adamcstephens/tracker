defmodule TrackerWeb.SessionTest do
  use TrackerWeb.ConnCase, async: true

  @fourteen_days 14 * 24 * 60 * 60

  test "the session cookie persists for 14 days so a login survives a browser restart", %{
    conn: conn
  } do
    conn = get(conn, ~p"/")

    assert %{max_age: @fourteen_days} = conn.resp_cookies["_tracker_key"]
  end
end

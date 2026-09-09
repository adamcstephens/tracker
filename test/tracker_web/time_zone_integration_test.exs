defmodule TrackerWeb.TimeZoneIntegrationTest do
  use TrackerWeb.ConnCase, async: true

  import Tracker.Fixtures

  alias AshAuthentication.Plug.Helpers
  alias Tracker.Accounts.User

  @merged_at ~U[2026-07-01 16:05:00Z]

  test "anonymous visitors with an encoded time zone cookie receive localized initial HTML", %{
    conn: conn
  } do
    change!(nil, %{merged_at: @merged_at})

    conn =
      conn
      |> put_req_cookie("_tracker_time_zone", "America%2FNew_York")
      |> get(~p"/changes")

    assert html_response(conn, 200) =~ "Merged on 2026-07-01 12:05 EDT"
  end

  test "an invalid anonymous time zone cookie falls back to UTC", %{conn: conn} do
    change!(nil, %{merged_at: @merged_at})

    conn = conn |> put_req_cookie("_tracker_time_zone", "Not/A_Zone") |> get(~p"/changes")

    assert html_response(conn, 200) =~ "Merged on 2026-07-01 16:05 UTC"
  end

  test "a signed-in user's preference overrides the anonymous cookie", %{conn: conn} do
    change!(nil, %{merged_at: @merged_at})

    user =
      register_user!() |> then(&User.set_time_zone!(&1, %{time_zone: "Europe/Paris"}, actor: &1))

    conn =
      conn
      |> log_in(user)
      |> put_req_cookie("_tracker_time_zone", "America/New_York")
      |> get(~p"/changes")

    assert html_response(conn, 200) =~ "Merged on 2026-07-01 18:05 CEST"
  end

  test "a signed-in user without a preference uses the browser cookie", %{conn: conn} do
    change!(nil, %{merged_at: @merged_at})
    user = register_user!()

    conn =
      conn
      |> log_in(user)
      |> put_req_cookie("_tracker_time_zone", "America%2FNew_York")
      |> get(~p"/changes")

    assert html_response(conn, 200) =~ "Merged on 2026-07-01 12:05 EDT"
  end

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Helpers.store_in_session(user)
  end
end

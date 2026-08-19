defmodule TrackerWeb.Browser.SmokeTest do
  use TrackerWeb.PlaywrightCase

  test "serves the packages page to a real browser", %{conn: conn} do
    conn
    |> visit(~p"/packages")
    |> assert_has(".app-nav a[aria-current=page]", text: "Packages")
    |> assert_has("#page-search-input")
  end
end

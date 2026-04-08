defmodule TrackerWeb.LensControllerTest do
  use TrackerWeb.ConnCase, async: true

  alias TrackerWeb.Lens

  describe "POST /lens" do
    test "sets signed cookie and redirects to referer", %{conn: conn} do
      conn =
        conn
        |> put_req_header("referer", "/packages/firefox")
        |> post("/lens", %{"channel" => "nixos-unstable"})

      assert redirected_to(conn) == "/packages/firefox"

      cookie = conn.resp_cookies["_tracker_lens"]
      assert cookie
      assert cookie.max_age == Lens.cookie_max_age()

      {:ok, value} = Lens.verify_cookie(cookie.value)
      assert value == "nixos-unstable"
    end

    test "includes revision in cookie when provided", %{conn: conn} do
      conn = post(conn, "/lens", %{"channel" => "nixos-unstable", "rev" => "abc123"})

      cookie = conn.resp_cookies["_tracker_lens"]
      {:ok, value} = Lens.verify_cookie(cookie.value)
      assert value == "nixos-unstable:abc123"
    end

    test "redirects to / when no referer", %{conn: conn} do
      conn = post(conn, "/lens", %{"channel" => "nixos-unstable"})

      assert redirected_to(conn) == "/"
    end

    test "ignores empty revision", %{conn: conn} do
      conn = post(conn, "/lens", %{"channel" => "nixos-unstable", "rev" => ""})

      cookie = conn.resp_cookies["_tracker_lens"]
      {:ok, value} = Lens.verify_cookie(cookie.value)
      assert value == "nixos-unstable"
    end
  end
end

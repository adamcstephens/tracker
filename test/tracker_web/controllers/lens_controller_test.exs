defmodule TrackerWeb.LensControllerTest do
  use TrackerWeb.ConnCase, async: true

  alias TrackerWeb.Lens

  describe "POST /lens" do
    test "sets signed cookie and redirects to referer", %{conn: conn} do
      conn =
        conn
        |> put_req_header("referer", "/packages/firefox")
        |> post("/lens", %{"channel" => "nixos-unstable"})

      assert redirected_to(conn) == "/packages/firefox?lens_channel=nixos-unstable"

      cookie = conn.resp_cookies["_tracker_lens"]
      assert cookie
      assert cookie.max_age == Lens.cookie_max_age()
      # The live lens rewrites this cookie from JS, which a browser blocks for
      # an http_only cookie of the same name.
      refute cookie.http_only

      {:ok, value} = Lens.verify_cookie(cookie.value)
      assert value == "nixos-unstable"
    end

    test "includes revision in cookie when provided", %{conn: conn} do
      conn = post(conn, "/lens", %{"channel" => "nixos-unstable", "rev" => "abc123"})

      assert redirected_to(conn) == "/?lens_channel=nixos-unstable&lens_rev=abc123"

      cookie = conn.resp_cookies["_tracker_lens"]
      {:ok, value} = Lens.verify_cookie(cookie.value)
      assert value == "nixos-unstable:abc123"
    end

    test "redirects to / when no referer", %{conn: conn} do
      conn = post(conn, "/lens", %{"channel" => "nixos-unstable"})

      assert redirected_to(conn) == "/?lens_channel=nixos-unstable"
    end

    test "ignores empty revision", %{conn: conn} do
      conn = post(conn, "/lens", %{"channel" => "nixos-unstable", "rev" => ""})

      cookie = conn.resp_cookies["_tracker_lens"]
      {:ok, value} = Lens.verify_cookie(cookie.value)
      assert value == "nixos-unstable"
    end

    test "strips scheme/host when referer is an absolute same-host URL", %{conn: conn} do
      conn =
        conn
        |> put_req_header("referer", "http://#{conn.host}/packages?search=foo")
        |> post("/lens", %{"channel" => "nixos-unstable"})

      assert redirected_to(conn) == "/packages?lens_channel=nixos-unstable&search=foo"
    end

    test "falls back to / when referer is a cross-origin URL", %{conn: conn} do
      conn =
        conn
        |> put_req_header("referer", "https://evil.example/attack")
        |> post("/lens", %{"channel" => "nixos-unstable"})

      assert redirected_to(conn) == "/?lens_channel=nixos-unstable"
    end
  end
end

defmodule TrackerWeb.Plug.LensTest do
  use TrackerWeb.ConnCase, async: true

  alias TrackerWeb.Lens

  describe "call/2" do
    test "without cookie, session has no lens keys" do
      conn =
        build_conn(:get, "/")
        |> init_test_session(%{})
        |> TrackerWeb.Plug.Lens.call([])

      refute get_session(conn, "lens_channel_name")
      refute get_session(conn, "lens_rev")
    end

    test "with valid signed cookie containing channel only, sets session" do
      token = Phoenix.Token.sign(TrackerWeb.Endpoint, Lens.cookie_salt(), "nixos-unstable")

      conn =
        build_conn(:get, "/")
        |> put_req_cookie("_tracker_lens", token)
        |> init_test_session(%{})
        |> TrackerWeb.Plug.Lens.call([])

      assert get_session(conn, "lens_channel_name") == "nixos-unstable"
      refute get_session(conn, "lens_rev")
    end

    test "with valid signed cookie containing channel and rev, sets both" do
      token = Phoenix.Token.sign(TrackerWeb.Endpoint, Lens.cookie_salt(), "nixos-unstable:abc123")

      conn =
        build_conn(:get, "/")
        |> put_req_cookie("_tracker_lens", token)
        |> init_test_session(%{})
        |> TrackerWeb.Plug.Lens.call([])

      assert get_session(conn, "lens_channel_name") == "nixos-unstable"
      assert get_session(conn, "lens_rev") == "abc123"
    end

    test "with tampered cookie, session has no lens keys" do
      conn =
        build_conn(:get, "/")
        |> put_req_cookie("_tracker_lens", "tampered-garbage")
        |> init_test_session(%{})
        |> TrackerWeb.Plug.Lens.call([])

      refute get_session(conn, "lens_channel_name")
      refute get_session(conn, "lens_rev")
    end
  end
end

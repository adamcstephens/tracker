defmodule TrackerWeb.Plug.StoreReturnToTest do
  use TrackerWeb.ConnCase, async: true

  import Tracker.Fixtures

  alias TrackerWeb.Plug.StoreReturnTo

  defp call(conn), do: StoreReturnTo.call(conn, StoreReturnTo.init([]))

  describe "call/2" do
    test "stores the requested path for unauthenticated GETs" do
      conn =
        build_conn(:get, "/packages/oban")
        |> Plug.Test.init_test_session(%{})
        |> call()

      assert get_session(conn, :return_to) == "/packages/oban"
    end

    test "keeps the query string" do
      conn =
        build_conn(:get, "/changes?status=open")
        |> Plug.Test.init_test_session(%{})
        |> call()

      assert get_session(conn, :return_to) == "/changes?status=open"
    end

    test "does not store when a user is signed in" do
      conn =
        build_conn(:get, "/packages/oban")
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.assign(:current_user, %Tracker.Accounts.User{id: "0"})
        |> call()

      refute get_session(conn, :return_to)
    end

    test "does not store for non-GET requests" do
      conn =
        build_conn(:post, "/lens")
        |> Plug.Test.init_test_session(%{})
        |> call()

      refute get_session(conn, :return_to)
    end

    test "skips auth and feed paths" do
      for path <- [
            "/sign-in",
            "/sign-out",
            "/auth/user/github",
            "/register",
            "/reset",
            "/feeds/channels/nixos-unstable"
          ] do
        conn =
          build_conn(:get, path)
          |> Plug.Test.init_test_session(%{})
          |> call()

        refute get_session(conn, :return_to), "expected #{path} not to be stored"
      end
    end

    test "overwrites a previously stored path" do
      conn =
        build_conn(:get, "/options")
        |> Plug.Test.init_test_session(%{return_to: "/packages"})
        |> call()

      assert get_session(conn, :return_to) == "/options"
    end
  end

  describe "through the endpoint" do
    test "login after a bounce returns to the originally requested page" do
      user = register_user!()

      bounced = get(build_conn(), ~p"/account/settings")
      assert redirected_to(bounced) == ~p"/sign-in"
      assert get_session(bounced, :return_to) == "/account/settings"

      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{return_to: get_session(bounced, :return_to)})
        |> TrackerWeb.AuthController.success({:github, :sign_in}, user, nil)

      assert redirected_to(conn) == ~p"/account/settings"
      refute get_session(conn, :return_to)
    end
  end
end

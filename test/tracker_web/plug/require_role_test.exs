defmodule TrackerWeb.Plug.RequireRoleTest do
  use TrackerWeb.ConnCase, async: true

  alias Tracker.Accounts.User
  alias TrackerWeb.Plug.RequireRole

  describe "call/2" do
    test "passes through when actor has the required role" do
      user = %User{id: "0", roles: [:user, :admin]}

      conn =
        build_conn(:get, "/")
        |> Plug.Conn.assign(:current_user, user)
        |> RequireRole.call(RequireRole.init(role: :admin))

      refute conn.halted
    end

    test "returns 403 when actor lacks the required role" do
      user = %User{id: "0", roles: [:user]}

      conn =
        build_conn(:get, "/")
        |> Plug.Conn.assign(:current_user, user)
        |> RequireRole.call(RequireRole.init(role: :admin))

      assert conn.halted
      assert conn.status == 403
      assert conn.resp_body =~ "forbidden"
    end

    test "returns 401 when current_user is absent" do
      conn =
        build_conn(:get, "/")
        |> RequireRole.call(RequireRole.init(role: :admin))

      assert conn.halted
      assert conn.status == 401
    end

    test "raises when :role option is missing" do
      assert_raise KeyError, fn -> RequireRole.init([]) end
    end
  end
end

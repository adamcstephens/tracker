defmodule TrackerWeb.Plug.BearerAuthTest do
  use TrackerWeb.ConnCase, async: true

  alias Tracker.Accounts.{ApiToken, User}
  alias TrackerWeb.Plug.BearerAuth

  describe "call/2" do
    test "valid api token assigns current_user and current_user_token" do
      user = register_via_github!()
      {:ok, %{token: jwt, jti: jti}} = ApiToken.issue(user.id, %{}, actor: user)

      conn =
        build_conn(:get, "/")
        |> put_req_header("authorization", "Bearer " <> jwt)
        |> BearerAuth.call(BearerAuth.init([]))

      refute conn.halted
      assert conn.assigns.current_user.id == user.id
      assert conn.assigns.current_user_token == jti
    end

    test "missing header returns 401" do
      conn =
        build_conn(:get, "/")
        |> BearerAuth.call(BearerAuth.init([]))

      assert conn.halted
      assert conn.status == 401
      assert conn.resp_body =~ "missing_bearer_token"
    end

    test "malformed jwt returns 401" do
      conn =
        build_conn(:get, "/")
        |> put_req_header("authorization", "Bearer not-a-jwt")
        |> BearerAuth.call(BearerAuth.init([]))

      assert conn.halted
      assert conn.status == 401
      assert conn.resp_body =~ "invalid_token"
    end

    test "non-api purpose returns 401" do
      user = register_via_github!()
      {:ok, jwt, _claims} = AshAuthentication.Jwt.token_for_user(user)

      conn =
        build_conn(:get, "/")
        |> put_req_header("authorization", "Bearer " <> jwt)
        |> BearerAuth.call(BearerAuth.init([]))

      assert conn.halted
      assert conn.status == 401
      assert conn.resp_body =~ "invalid_purpose"
    end

    test "revoked token returns 401" do
      user = register_via_github!()
      {:ok, %{token: jwt, jti: jti}} = ApiToken.issue(user.id, %{}, actor: user)
      {:ok, _} = ApiToken.revoke(jti, actor: user)

      conn =
        build_conn(:get, "/")
        |> put_req_header("authorization", "Bearer " <> jwt)
        |> BearerAuth.call(BearerAuth.init([]))

      assert conn.halted
      assert conn.status == 401
    end

    test "expired token returns 401" do
      user = register_via_github!()
      {:ok, %{token: jwt}} = ApiToken.issue(user.id, %{expires_in: 1}, actor: user)

      Process.sleep(1100)

      conn =
        build_conn(:get, "/")
        |> put_req_header("authorization", "Bearer " <> jwt)
        |> BearerAuth.call(BearerAuth.init([]))

      assert conn.halted
      assert conn.status == 401
    end
  end

  defp register_via_github!(overrides \\ %{}) do
    user_info =
      Map.merge(
        %{
          "id" => System.unique_integer([:positive]),
          "login" => "user_#{System.unique_integer([:positive])}"
        },
        overrides
      )

    User
    |> Ash.Changeset.for_create(:register_with_github,
      user_info: user_info,
      oauth_tokens: %{"access_token" => "tok"}
    )
    |> Ash.create!(authorize?: false)
  end
end

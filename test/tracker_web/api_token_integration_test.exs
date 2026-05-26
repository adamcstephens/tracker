defmodule TrackerWeb.ApiTokenIntegrationTest do
  use TrackerWeb.ConnCase, async: true

  alias Tracker.Accounts.{ApiToken, User}
  alias TrackerWeb.Plug.{BearerAuth, RequireRole}

  describe "full bearer auth flow" do
    test "admin creates a service account, issues a token, and a request guarded by BearerAuth+RequireRole succeeds" do
      admin = register_via_github!() |> grant_admin!()
      service = User.create_service_account!("ingest", [:user, :admin], actor: admin)
      {:ok, %{token: jwt}} = ApiToken.issue(service.id, %{label: "robot"}, actor: admin)

      conn = call_guarded(jwt, :admin)

      refute conn.halted
      assert conn.assigns.current_user.id == service.id
      assert User.has_role?(conn.assigns.current_user, :admin)
    end

    test "missing header is rejected with 401 by the bearer auth plug" do
      conn = call_guarded(nil, :admin)

      assert conn.halted
      assert conn.status == 401
    end

    test "revoked token is rejected with 401" do
      admin = register_via_github!() |> grant_admin!()
      service = User.create_service_account!("ingest", [:user, :admin], actor: admin)
      {:ok, %{token: jwt, jti: jti}} = ApiToken.issue(service.id, %{}, actor: admin)
      {:ok, _} = ApiToken.revoke(jti, actor: admin)

      conn = call_guarded(jwt, :admin)

      assert conn.halted
      assert conn.status == 401
    end

    test "token whose user lacks the required role is rejected with 403" do
      admin = register_via_github!() |> grant_admin!()
      service = User.create_service_account!("plain", [:user], actor: admin)
      {:ok, %{token: jwt}} = ApiToken.issue(service.id, %{}, actor: admin)

      conn = call_guarded(jwt, :admin)

      assert conn.halted
      assert conn.status == 403
    end

    test "non-admin attempting to issue a token for another user is rejected" do
      alice = register_via_github!()
      bob = register_via_github!()

      assert {:error, %Ash.Error.Forbidden{}} =
               ApiToken.issue(bob.id, %{}, actor: alice)
    end
  end

  defp call_guarded(jwt, required_role) do
    build_conn(:get, "/")
    |> maybe_put_bearer(jwt)
    |> BearerAuth.call(BearerAuth.init([]))
    |> require_role_if_alive(required_role)
  end

  defp maybe_put_bearer(conn, nil), do: conn
  defp maybe_put_bearer(conn, jwt), do: put_req_header(conn, "authorization", "Bearer " <> jwt)

  defp require_role_if_alive(%{halted: true} = conn, _role), do: conn

  defp require_role_if_alive(conn, role),
    do: RequireRole.call(conn, RequireRole.init(role: role))

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

  defp grant_admin!(%User{} = user) do
    import Ecto.Query

    Tracker.Repo.update_all(
      from(u in "users", where: u.github_id == ^user.github_id),
      set: [roles: ["user", "admin"]]
    )

    refreshed = Ash.get!(User, user.id, authorize?: false)
    %{refreshed | __metadata__: user.__metadata__}
  end
end

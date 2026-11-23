defmodule TrackerWeb.AuthControllerTest do
  use TrackerWeb.ConnCase, async: true

  import ExUnit.CaptureLog

  alias AshAuthentication.Errors.AuthenticationFailed
  alias AshAuthentication.Errors.CannotConfirmUnconfirmedUser
  alias TrackerWeb.AuthController

  setup %{conn: conn} do
    {:ok, conn: conn |> Plug.Test.init_test_session(%{}) |> Phoenix.Controller.fetch_flash([])}
  end

  test "logs a missing reason and shows a generic sign-in failure", %{conn: conn} do
    log =
      capture_log(fn ->
        conn = AuthController.failure(conn, {:github, :callback}, nil)
        assert redirected_to(conn) == "/sign-in"
        assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Sign-in failed"
      end)

    assert log =~ "[warning]"
    assert log =~ "github"
    assert log =~ "callback"
    assert log =~ "no_reason"
  end

  test "logs nested error types without error contents and keeps confirmation guidance", %{
    conn: conn
  } do
    reason = %AuthenticationFailed{
      caused_by: %Ash.Error.Forbidden{errors: [%CannotConfirmUnconfirmedUser{}]}
    }

    log =
      capture_log(fn ->
        conn = AuthController.failure(conn, {:github, :callback}, reason)
        assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "have not confirmed your account"
      end)

    assert log =~ "AuthenticationFailed"
    assert log =~ "Forbidden"
    assert log =~ "CannotConfirmUnconfirmedUser"

    log =
      capture_log(fn ->
        reason = %AuthenticationFailed{caused_by: %RuntimeError{message: "sensitive-oauth-value"}}
        AuthController.failure(conn, {:github, :callback}, reason)
      end)

    assert log =~ "RuntimeError"
    refute log =~ "sensitive-oauth-value"
  end

  test "logs the database constraint without database error details", %{conn: conn} do
    reason = %Ash.Error.Invalid{
      errors: [
        %Ash.Error.Changes.InvalidAttribute{
          private_vars: [
            constraint: "users_unique_github_username_index",
            detail: "sensitive-user-data"
          ]
        }
      ]
    }

    log =
      capture_log(fn ->
        AuthController.failure(conn, {:github, :callback}, reason)
      end)

    assert log =~ "InvalidAttribute"
    assert log =~ "users_unique_github_username_index"
    refute log =~ "sensitive-user-data"
  end
end

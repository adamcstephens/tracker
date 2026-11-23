defmodule TrackerWeb.DevLoginController do
  use TrackerWeb, :controller

  require Logger

  alias AshAuthentication.Plug.Helpers

  def create(conn, %{"token" => token}) do
    case Tracker.DevLogin.authenticate(token) do
      {:ok, user} ->
        conn
        |> Helpers.store_in_session(user)
        |> assign(:current_user, user)
        |> redirect(to: ~p"/")

      :error ->
        Logger.warning(
          msg: "Sign-in failed",
          strategy: "dev_login",
          phase: "create",
          errors: "invalid_dev_credentials"
        )

        conn
        |> put_flash(:error, "That dev login token is not valid.")
        |> redirect(to: ~p"/sign-in")
    end
  end
end

defmodule TrackerWeb.DevLoginController do
  use TrackerWeb, :controller

  alias AshAuthentication.Plug.Helpers

  def create(conn, %{"token" => token}) do
    case Tracker.DevLogin.authenticate(token) do
      {:ok, user} ->
        conn
        |> Helpers.store_in_session(user)
        |> assign(:current_user, user)
        |> redirect(to: ~p"/")

      :error ->
        conn
        |> put_flash(:error, "That dev login token is not valid.")
        |> redirect(to: ~p"/sign-in")
    end
  end
end

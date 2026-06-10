defmodule TrackerWeb.Plug.RequireRole do
  @moduledoc """
  Gates a request behind a role on the assigned `:current_user`.

  Options:

    * `:role` — required role atom (e.g. `:admin`).
    * `:format` — `:json` (default) responds with 401/403 JSON errors;
      `:browser` redirects to the sign-in page when unauthenticated and to
      the home page when the role is missing.
  """
  @behaviour Plug

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  use TrackerWeb, :verified_routes

  alias Tracker.Accounts.User

  @impl Plug
  def init(opts) do
    role = Keyword.fetch!(opts, :role)
    format = Keyword.get(opts, :format, :json)
    [role: role, format: format]
  end

  @impl Plug
  def call(conn, role: role, format: format) do
    case conn.assigns[:current_user] do
      nil -> deny(conn, format, :unauthenticated)
      %User{} = user -> check_role(conn, user, role, format)
    end
  end

  defp check_role(conn, user, role, format) do
    if User.has_role?(user, role) do
      conn
    else
      deny(conn, format, :forbidden)
    end
  end

  defp deny(conn, :json, reason) do
    status = if reason == :unauthenticated, do: 401, else: 403
    body = Jason.encode!(%{error: reason})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
    |> halt()
  end

  defp deny(conn, :browser, reason) do
    to = if reason == :unauthenticated, do: ~p"/sign-in", else: ~p"/"

    conn
    |> redirect(to: to)
    |> halt()
  end
end

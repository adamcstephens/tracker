defmodule TrackerWeb.Plug.RequireRole do
  @moduledoc """
  Gates a request behind a role on the assigned `:current_user`.

  Options:

    * `:role` — required role atom (e.g. `:admin`).
  """
  @behaviour Plug

  import Plug.Conn

  alias Tracker.Accounts.User

  @impl Plug
  def init(opts) do
    role = Keyword.fetch!(opts, :role)
    [role: role]
  end

  @impl Plug
  def call(conn, role: role) do
    case conn.assigns[:current_user] do
      nil -> deny(conn, 401, "unauthenticated")
      %User{} = user -> check_role(conn, user, role)
    end
  end

  defp check_role(conn, user, role) do
    if User.has_role?(user, role) do
      conn
    else
      deny(conn, 403, "forbidden")
    end
  end

  defp deny(conn, status, reason) do
    body = Jason.encode!(%{error: reason})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
    |> halt()
  end
end

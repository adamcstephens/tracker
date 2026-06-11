defmodule TrackerWeb.Plug.StoreReturnTo do
  @moduledoc """
  Remembers the last page an anonymous visitor requested so
  `TrackerWeb.AuthController.success/4` can send them back after login.

  Stores the current path (including query string) in the `:return_to`
  session key for unauthenticated GET requests, overwriting any previous
  value so the latest page wins. Auth routes and feeds are skipped: they
  are not pages a user would want to land back on.
  """
  @behaviour Plug

  import Plug.Conn
  import Phoenix.Controller, only: [current_path: 1]

  @skip_prefixes ["/sign-in", "/sign-out", "/auth", "/register", "/reset", "/feeds"]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: "GET"} = conn, _opts) do
    if conn.assigns[:current_user] || skip?(conn.request_path) do
      conn
    else
      put_session(conn, :return_to, current_path(conn))
    end
  end

  def call(conn, _opts), do: conn

  defp skip?(path) do
    Enum.any?(@skip_prefixes, fn prefix ->
      path == prefix or String.starts_with?(path, prefix <> "/")
    end)
  end
end

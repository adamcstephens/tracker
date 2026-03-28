defmodule TrackerWeb.Plug.HealthCheck do
  import Plug.Conn

  def init(opts), do: opts

  def call(%Plug.Conn{request_path: "/health"} = conn, _opts) do
    {:ok, _} = Tracker.Repo.query("SELECT 1")

    conn
    |> send_resp(200, ":ok")
    |> halt()
  end

  def call(conn, _opts), do: conn
end

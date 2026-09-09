defmodule TrackerWeb.Plug.TimeZone do
  import Plug.Conn

  alias Tracker.TimeZone

  @cookie_name "_tracker_time_zone"
  @session_key "time_zone"

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = fetch_cookies(conn)
    time_zone = resolve(conn.assigns[:current_user], conn.req_cookies[@cookie_name])

    conn
    |> assign(:time_zone, time_zone)
    |> put_session(@session_key, time_zone)
  end

  def resolve(%{time_zone: time_zone}, _cookie) when is_binary(time_zone), do: time_zone

  def resolve(_user, cookie) when is_binary(cookie) do
    time_zone = URI.decode(cookie)

    if TimeZone.valid?(time_zone), do: time_zone, else: TimeZone.default()
  end

  def resolve(_user, _cookie), do: TimeZone.default()
end

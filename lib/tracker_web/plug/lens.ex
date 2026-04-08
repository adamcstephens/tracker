defmodule TrackerWeb.Plug.Lens do
  @moduledoc """
  Reads the `_tracker_lens` cookie (containing a signed Phoenix.Token)
  and populates the session with `lens_channel_name` and `lens_rev`
  for downstream LiveView hooks.
  """

  import Plug.Conn

  alias TrackerWeb.Lens

  @cookie_name "_tracker_lens"

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = fetch_cookies(conn)

    case conn.req_cookies[@cookie_name] do
      nil ->
        conn

      token when is_binary(token) ->
        case Lens.verify_cookie(token) do
          {:ok, value} ->
            {channel_name, rev} = Lens.from_cookie(value)
            put_lens_session(conn, channel_name, rev)

          :error ->
            conn
        end

      _ ->
        conn
    end
  end

  defp put_lens_session(conn, nil, _rev), do: conn

  defp put_lens_session(conn, channel_name, nil) do
    put_session(conn, "lens_channel_name", channel_name)
  end

  defp put_lens_session(conn, channel_name, rev) do
    conn
    |> put_session("lens_channel_name", channel_name)
    |> put_session("lens_rev", rev)
  end
end

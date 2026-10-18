defmodule TrackerWeb.Plug.Metrics do
  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: PromEx.Plug.init(opts)

  @impl Plug
  def call(%Plug.Conn{request_path: "/metrics"} = conn, opts) do
    case Application.get_env(:tracker, :metrics_token) do
      token when is_binary(token) and byte_size(token) > 0 -> authorize(conn, token, opts)
      _ -> reject(conn, 404, "Not Found")
    end
  end

  def call(%Plug.Conn{} = conn, _opts), do: conn

  defp authorize(%Plug.Conn{} = conn, token, opts) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> provided] ->
        if Plug.Crypto.secure_compare(provided, token) do
          serve(conn, opts)
        else
          deny(conn)
        end

      _ ->
        deny(conn)
    end
  end

  defp serve(%Plug.Conn{method: "GET"} = conn, opts), do: PromEx.Plug.call(conn, opts)

  defp serve(%Plug.Conn{} = conn, _opts) do
    conn
    |> put_resp_header("allow", "GET")
    |> reject(405, "Method Not Allowed")
  end

  defp deny(%Plug.Conn{} = conn) do
    conn
    |> put_resp_header("www-authenticate", "Bearer")
    |> reject(401, "Unauthorized")
  end

  defp reject(%Plug.Conn{} = conn, status, body) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, body)
    |> halt()
  end
end

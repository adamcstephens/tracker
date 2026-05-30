defmodule TrackerWeb.LensController do
  use TrackerWeb, :controller

  alias TrackerWeb.Lens

  @cookie_name "_tracker_lens"

  def update(conn, params) do
    channel = Map.get(params, "channel", "")
    rev = Map.get(params, "rev", "")

    cookie_value =
      case rev do
        "" -> channel
        r -> "#{channel}:#{r}"
      end

    token = Phoenix.Token.sign(TrackerWeb.Endpoint, Lens.cookie_salt(), cookie_value)
    redirect_to = safe_referer_path(conn, get_req_header(conn, "referer"))

    conn
    |> put_resp_cookie(@cookie_name, token,
      max_age: Lens.cookie_max_age(),
      http_only: true,
      same_site: "Lax"
    )
    |> redirect(to: redirect_to)
  end

  defp safe_referer_path(_conn, []), do: "/"

  defp safe_referer_path(conn, [referer | _]) do
    case URI.parse(referer) do
      %URI{host: nil, path: path} when is_binary(path) ->
        path_with_query(path, referer)

      %URI{host: host, path: path} when is_binary(path) ->
        if host == conn.host, do: path_with_query(path, referer), else: "/"

      _ ->
        "/"
    end
  end

  defp path_with_query(path, referer) do
    case URI.parse(referer).query do
      nil -> path
      "" -> path
      query -> path <> "?" <> query
    end
  end
end

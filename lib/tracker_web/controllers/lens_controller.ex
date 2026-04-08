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
    redirect_to = get_req_header(conn, "referer") |> List.first() || "/"

    conn
    |> put_resp_cookie(@cookie_name, token,
      max_age: Lens.cookie_max_age(),
      http_only: true,
      same_site: "Lax"
    )
    |> redirect(to: redirect_to)
  end
end

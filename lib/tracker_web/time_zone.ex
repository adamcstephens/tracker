defmodule TrackerWeb.TimeZone do
  import Phoenix.Component

  alias TrackerWeb.Plug.TimeZone

  def on_mount(:default, _params, session, socket) do
    time_zone = TimeZone.resolve(socket.assigns[:current_user], session["time_zone"])
    {:cont, assign(socket, :time_zone, time_zone)}
  end
end

defmodule TrackerWeb.LensHook do
  @moduledoc """
  LiveView on_mount hook that resolves the channel lens from URL params
  or session and assigns it to the socket.

  Priority: URL params (`lens_channel`, `lens_rev`) > session > default stable channel.
  """

  import Phoenix.Component

  alias TrackerWeb.Lens

  def on_mount(:default, params, session, socket) do
    {channel_name, rev} = resolve_from_params_or_session(params, session)
    lens = Lens.resolve(channel_name, rev)
    {:cont, assign(socket, :lens, lens)}
  end

  defp resolve_from_params_or_session(params, session) do
    channel_name = params["lens_channel"] || session["lens_channel_name"]
    rev = params["lens_rev"] || session["lens_rev"]
    {channel_name, rev}
  end
end

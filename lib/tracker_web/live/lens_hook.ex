defmodule TrackerWeb.LensHook do
  @moduledoc """
  LiveView on_mount hook that resolves the channel lens and assigns it to the socket.

  Priority: connect_params (`_lens_channel`, `_lens_rev`) > URL params (`lens_channel`,
  `lens_rev`) > session > default stable channel.

  Connect params are passed by the JS client on every LiveView join, keeping the lens
  in sync across live navigations even when the session cookie hasn't been refreshed.
  """

  import Phoenix.Component
  import Phoenix.LiveView, only: [connected?: 1, get_connect_params: 1]

  alias TrackerWeb.Lens

  def on_mount(:default, params, session, socket) do
    {channel_name, rev} = resolve_lens_source(params, session, socket)
    lens = Lens.resolve(channel_name, rev)
    {:cont, assign(socket, :lens, lens)}
  end

  defp resolve_lens_source(params, session, socket) do
    connect = if connected?(socket), do: get_connect_params(socket), else: %{}

    channel_name =
      connect["_lens_channel"] || params["lens_channel"] || session["lens_channel_name"]

    rev = connect["_lens_rev"] || params["lens_rev"] || session["lens_rev"]

    {channel_name, rev}
  end
end

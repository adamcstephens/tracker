defmodule TrackerWeb.LensHandlers do
  @moduledoc """
  Shared handlers for lens change events sent by `TrackerWeb.LensComponent`.

  The component sends `{:set_lens, channel_name, rev}` to the parent LiveView.
  Each LiveView should handle this message and call `handle_lens_change/3` to
  update the socket, then do any page-specific data reloading.
  """

  import Phoenix.Component
  import Phoenix.LiveView, only: [push_event: 3]

  alias TrackerWeb.Lens

  @doc """
  Updates the socket's lens assign and pushes a cookie event to persist
  the change client-side. Returns the updated socket.
  """
  @spec handle_lens_change(Phoenix.LiveView.Socket.t(), String.t(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def handle_lens_change(socket, channel_name, rev) do
    lens = Lens.resolve(channel_name, rev)
    cookie_token = Lens.sign_cookie(lens)

    rev_hash = if lens.revision, do: lens.revision.revision
    lens_channel = if lens.all?, do: "all", else: lens.channel.name

    socket
    |> assign(:lens, lens)
    |> push_event("set_lens_cookie", %{
      value: cookie_token,
      max_age: Lens.cookie_max_age(),
      lens_channel: lens_channel,
      lens_rev: rev_hash
    })
  end
end

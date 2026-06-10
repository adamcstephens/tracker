defmodule TrackerWeb.Plug.InteractiveUI do
  @moduledoc """
  Sets `conn.assigns.interactive?` and the matching socket assign for
  LiveView mounts, based on the current user's `live_ui` preference.

  Anonymous users are never interactive. Authenticated users default to
  interactive but can opt out via `Tracker.Accounts.User.set_live_ui/2`.
  The flag drives the script tag in the root layout and the LiveView
  socket on_mount halt, so opted-out users never establish a WebSocket.

  Views in `@forced_views` only work live (their routes pipe through
  `:force_interactive` for the dead render), so they are interactive
  regardless of the user's preference and never halted. This lets them
  share the sitewide live_session for live navigation.
  """

  import Plug.Conn

  @forced_views [TrackerWeb.InboxLive.Index]

  def init(opts), do: opts

  def call(conn, _opts) do
    assign(conn, :interactive?, interactive_for?(conn.assigns[:current_user]))
  end

  def on_mount(:default, _params, _session, socket) do
    user = socket.assigns[:current_user]
    interactive? = socket.view in @forced_views or interactive_for?(user)
    opted_out? = user != nil and not interactive?

    if Phoenix.LiveView.connected?(socket) and opted_out? do
      {:halt, Phoenix.LiveView.redirect(socket, to: "/")}
    else
      {:cont, Phoenix.Component.assign(socket, :interactive?, interactive?)}
    end
  end

  def interactive_for?(nil), do: false
  def interactive_for?(%{live_ui: live_ui}), do: live_ui
end

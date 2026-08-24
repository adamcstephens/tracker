defmodule TrackerWeb.InboxBadgeHook do
  @moduledoc """
  Assigns `:unread_notification_count` for the chrome inbox icon badge and
  keeps it current on every page.

  The hook owns the connected session's subscription to the user's
  notification topic, so a notification arriving — or being read on another
  device — moves the badge wherever you are. Only `InboxLive.Index` handles
  these messages itself, so they are halted for every other view.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]

  alias Tracker.Accounts.User
  alias Tracker.Notifications.Notification

  def on_mount(:default, _params, _session, socket) do
    case socket.assigns[:current_user] do
      nil ->
        {:cont, assign(socket, :unread_notification_count, 0)}

      user ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Tracker.PubSub, "notifications:#{user.id}")
        end

        {:cont,
         socket
         |> assign(:unread_notification_count, User.unread_notification_count(user))
         |> attach_hook(:inbox_badge, :handle_info, &refresh/2)}
    end
  end

  defp refresh(%Ash.Notifier.Notification{resource: Notification}, socket) do
    socket = assign(socket, :unread_notification_count, count(socket))

    if socket.view == TrackerWeb.InboxLive.Index,
      do: {:cont, socket},
      else: {:halt, socket}
  end

  defp refresh(_message, socket), do: {:cont, socket}

  defp count(socket), do: User.unread_notification_count(socket.assigns.current_user)
end

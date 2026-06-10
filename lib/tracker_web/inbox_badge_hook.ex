defmodule TrackerWeb.InboxBadgeHook do
  @moduledoc """
  Assigns `:unread_notification_count` for the chrome inbox icon badge.

  Computed once on mount; the inbox LiveView keeps the assign current as
  notifications are read there.
  """
  import Phoenix.Component, only: [assign: 3]

  alias Tracker.Accounts.User

  def on_mount(:default, _params, _session, socket) do
    count =
      case socket.assigns[:current_user] do
        nil -> 0
        user -> User.unread_notification_count(user)
      end

    {:cont, assign(socket, :unread_notification_count, count)}
  end
end

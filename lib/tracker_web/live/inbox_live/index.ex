defmodule TrackerWeb.InboxLive.Index do
  @moduledoc """
  The per-user in-app inbox. Lists durable notifications (read/unread),
  updates live as new ones are inserted, and doubles as the "everything
  affected" view when filtered to a single channel revision.
  """
  use TrackerWeb, :live_view

  alias Tracker.Accounts.User
  alias Tracker.Notifications.Notification
  alias TrackerWeb.NotificationPresenter

  @impl true
  def mount(_params, _session, socket) do
    user = ensure_feed_token(socket.assigns.current_user)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Tracker.PubSub, "notifications:#{user.id}")
    end

    {:ok,
     socket
     |> assign(:current_user, user)
     |> assign(:page_title, "Inbox")
     |> assign(:feed_path, feed_path(user))}
  end

  @impl true
  def handle_params(params, _url, socket) do
    channel_revision_id =
      case Integer.parse(params["channel_revision_id"] || "") do
        {id, _} -> id
        :error -> nil
      end

    {:noreply,
     socket
     |> assign(:channel_revision_id, channel_revision_id)
     |> load_notifications()}
  end

  @impl true
  def handle_event("mark-read", %{"id" => id}, socket) do
    id = String.to_integer(id)
    user = socket.assigns.current_user

    case Enum.find(socket.assigns.notifications, &(&1.id == id)) do
      nil -> {:noreply, socket}
      notification -> {:noreply, mark_and_reload(socket, notification, user)}
    end
  end

  def handle_event("regenerate-feed-token", _params, socket) do
    user = socket.assigns.current_user
    {:ok, updated} = User.rotate_feed_token(user, actor: user)

    {:noreply,
     socket
     |> assign(:current_user, updated)
     |> assign(:feed_path, feed_path(updated))
     |> put_flash(:info, "Feed URL regenerated. The previous URL no longer works.")}
  end

  def handle_event("mark-all-read", _params, socket) do
    user = socket.assigns.current_user

    socket.assigns.notifications
    |> Enum.filter(&is_nil(&1.read_at))
    |> case do
      [] -> :ok
      unread -> Ash.bulk_update!(unread, :mark_read, %{}, actor: user, return_records?: false)
    end

    {:noreply, load_notifications(socket)}
  end

  @impl true
  def handle_info(%Ash.Notifier.Notification{resource: Notification}, socket) do
    {:noreply, load_notifications(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp mark_and_reload(socket, notification, user) do
    {:ok, _} = Notification.mark_read(notification, actor: user)
    load_notifications(socket)
  end

  defp ensure_feed_token(%{feed_token: nil} = user) do
    case User.rotate_feed_token(user, actor: user) do
      {:ok, updated} -> updated
      _ -> user
    end
  end

  defp ensure_feed_token(user), do: user

  # A relative path so feed readers resolve it against the host the user
  # actually visited, rather than the endpoint's configured URL.
  defp feed_path(%{feed_token: nil}), do: nil
  defp feed_path(%{feed_token: token}), do: ~p"/feeds/notifications/#{token}"

  defp load_notifications(socket) do
    user = socket.assigns.current_user

    params =
      case socket.assigns.channel_revision_id do
        nil -> %{}
        id -> %{channel_revision_id: id}
      end

    notifications = Notification.for_user!(params, actor: user)

    socket
    |> assign(:notifications, notifications)
    |> assign(:unread_count, Enum.count(notifications, &is_nil(&1.read_at)))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Inbox
      <:subtitle :if={@unread_count > 0}>{@unread_count} unread</:subtitle>
      <:actions>
        <a
          :if={@feed_path}
          id="feed-link"
          href={@feed_path}
          title="Your private notifications Atom feed"
          style="display: flex; align-items: center;"
        >
          <img src="/images/feed.svg" alt="Atom feed" width="20" height="20" />
        </a>
        <button
          :if={@feed_path}
          id="regenerate-feed-token"
          type="button"
          phx-click="regenerate-feed-token"
          title="Generate a new feed URL and revoke the current one"
        >
          Regenerate feed
        </button>
        <button :if={@unread_count > 0} id="mark-all-read" type="button" phx-click="mark-all-read">
          Mark all read
        </button>
      </:actions>
    </.header>

    <p :if={@channel_revision_id} class="flash flash--info">
      Showing notifications for one revision. <.link navigate={~p"/inbox"}>Show all</.link>
    </p>

    <p :if={@notifications == []} id="inbox-empty">No notifications yet.</p>

    <ul :if={@notifications != []} id="notifications" class="inbox-list">
      <li
        :for={n <- @notifications}
        id={"notification-#{n.id}"}
        class={["inbox-item", is_nil(n.read_at) && "inbox-item--unread"]}
      >
        <div class="inbox-item__body">
          <%= if NotificationPresenter.path(n) do %>
            <.link navigate={NotificationPresenter.path(n)}>
              {NotificationPresenter.describe(n)}
            </.link>
          <% else %>
            <span>{NotificationPresenter.describe(n)}</span>
          <% end %>
          <time class="inbox-item__time">
            {Calendar.strftime(n.occurred_at, "%Y-%m-%d %H:%M UTC")}
          </time>
        </div>
        <button
          :if={is_nil(n.read_at)}
          type="button"
          phx-click="mark-read"
          phx-value-id={n.id}
        >
          Mark read
        </button>
      </li>
    </ul>
    """
  end
end

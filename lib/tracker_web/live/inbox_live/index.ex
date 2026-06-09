defmodule TrackerWeb.InboxLive.Index do
  @moduledoc """
  The per-user in-app inbox. Lists durable notifications (read/unread),
  updates live as new ones are inserted, and doubles as the "everything
  affected" view when filtered to a single channel revision.
  """
  use TrackerWeb, :live_view

  alias Tracker.Accounts.User
  alias Tracker.Notifications.Notification
  alias TrackerWeb.{FeedToken, NotificationPresenter}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Tracker.PubSub, "notifications:#{user.id}")
    end

    {:ok,
     socket
     |> assign(:page_title, "Inbox")
     |> assign(:feed_url, feed_url(user))}
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
     |> assign(:feed_url, feed_url(updated))
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

  defp feed_url(user), do: url(~p"/feeds/notifications/#{FeedToken.sign(user)}")

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
        <button :if={@unread_count > 0} id="mark-all-read" type="button" phx-click="mark-all-read">
          Mark all read
        </button>
      </:actions>
    </.header>

    <details class="inbox-feed" id="feed-subscription">
      <summary>Subscribe in a feed reader</summary>
      <p>
        Paste this private Atom URL into your feed reader. Anyone with the URL can read
        your notifications — regenerate it if it leaks.
      </p>
      <input id="feed-url" type="text" readonly value={@feed_url} />
      <button type="button" id="regenerate-feed-token" phx-click="regenerate-feed-token">
        Regenerate
      </button>
    </details>

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

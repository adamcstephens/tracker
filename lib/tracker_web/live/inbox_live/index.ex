defmodule TrackerWeb.InboxLive.Index do
  @moduledoc """
  The per-user in-app inbox. Lists durable notifications (read/unread),
  updates live as new ones are inserted, and doubles as the "everything
  affected" view when filtered to a single channel revision.
  """
  use TrackerWeb, :live_view

  alias Tracker.Notifications.Notification

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Tracker.PubSub, "notifications:#{user.id}")
    end

    {:ok, assign(socket, :page_title, "Inbox")}
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
          <%= if target_path(n) do %>
            <.link navigate={target_path(n)}>{describe(n)}</.link>
          <% else %>
            <span>{describe(n)}</span>
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

  defp describe(%{type: :channel_revision_published} = n),
    do: "New revision published on #{channel_name(n)}"

  defp describe(%{type: :package_added} = n),
    do: "#{package_name(n)} added to #{channel_name(n)}"

  defp describe(%{type: :package_removed} = n),
    do: "#{package_name(n)} removed from #{channel_name(n)}"

  defp describe(%{type: :package_version_changed} = n),
    do: "#{package_name(n)} updated on #{channel_name(n)}"

  defp describe(%{type: :change_propagated} = n) do
    case n.channel do
      nil -> "Change ##{change_number(n)} propagated"
      channel -> "Change ##{change_number(n)} reached #{channel.name}"
    end
  end

  defp target_path(%{type: :change_propagated} = n), do: ~p"/changes/#{change_number(n)}"

  defp target_path(%{
         type: :channel_revision_published,
         channel: %{name: name},
         channel_revision: %{revision: rev}
       }),
       do: ~p"/channels/#{name}/revisions/#{rev}"

  defp target_path(%{package: %{attribute: attribute}}) when is_binary(attribute),
    do: ~p"/packages/#{attribute}"

  defp target_path(_n), do: nil

  defp channel_name(%{channel: %{name: name}}), do: name
  defp channel_name(_), do: "a channel"

  defp package_name(%{package: %{attribute: attribute}}), do: attribute
  defp package_name(_), do: "a package"

  defp change_number(%{change: %{number: number}}), do: number
  defp change_number(_), do: nil
end

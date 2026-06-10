defmodule TrackerWeb.FeedController do
  use TrackerWeb, :controller

  alias Tracker.Accounts.User
  alias Tracker.Notifications.Notification
  alias TrackerWeb.NotificationPresenter

  @base_url "https://tracker-dev.junco.dev"

  def notifications(conn, %{"token" => token}) do
    case User.by_feed_token(token, authorize?: false) do
      {:ok, %User{} = user} ->
        render_notifications_feed(conn, user, token)

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "invalid feed token"}))
    end
  end

  defp render_notifications_feed(conn, user, token) do
    notifications = Notification.for_user!(actor: user) |> Enum.take(50)
    version_changes = NotificationPresenter.version_changes(notifications)

    latest_updated =
      case notifications do
        [n | _] -> n.occurred_at
        [] -> DateTime.utc_now()
      end

    feed =
      Atomex.Feed.new("#{@base_url}/inbox", latest_updated, "Your notifications - Tracker")
      |> Atomex.Feed.link("#{@base_url}/feeds/notifications/#{token}", rel: "self")
      |> Atomex.Feed.link("#{@base_url}/inbox", rel: "alternate")
      |> Atomex.Feed.entries(Enum.map(notifications, &notification_entry(&1, version_changes)))
      |> Atomex.Feed.build()
      |> Atomex.generate_document()

    conn
    |> put_resp_content_type("application/atom+xml")
    |> send_resp(200, feed)
  end

  defp notification_entry(notification, version_changes) do
    text = NotificationPresenter.describe(notification, version_changes)

    url =
      case NotificationPresenter.path(notification) do
        nil -> "#{@base_url}/inbox"
        path -> "#{@base_url}#{path}"
      end

    Atomex.Entry.new(
      "#{@base_url}/inbox#notification-#{notification.id}",
      notification.occurred_at,
      text
    )
    |> Atomex.Entry.link(url, rel: "alternate")
    |> Atomex.Entry.published(notification.occurred_at)
    |> Atomex.Entry.summary(text)
    |> Atomex.Entry.build()
  end

  def channel(conn, %{"channel" => channel_name}) do
    channel = Tracker.Nixpkgs.Channel.by_name!(channel_name)

    revisions =
      Tracker.Nixpkgs.ChannelRevision.list_by_channel!(channel.id,
        page: [limit: 50]
      ).results

    latest_updated =
      case revisions do
        [rev | _] -> rev.released_at
        [] -> DateTime.utc_now()
      end

    feed =
      Atomex.Feed.new(
        "#{@base_url}/channels/#{channel_name}",
        latest_updated,
        "#{channel_name} - Tracker"
      )
      |> Atomex.Feed.link("#{@base_url}/feeds/channels/#{channel_name}", rel: "self")
      |> Atomex.Feed.link("#{@base_url}/channels/#{channel_name}", rel: "alternate")
      |> Atomex.Feed.entries(Enum.map(revisions, &channel_entry(channel_name, &1)))
      |> Atomex.Feed.build()
      |> Atomex.generate_document()

    conn
    |> put_resp_content_type("application/atom+xml")
    |> send_resp(200, feed)
  end

  def package(conn, %{"name" => name} = params) do
    package = Tracker.Nixpkgs.Package.get_by_attribute!(name)
    channel_filter = Map.get(params, "channel", "")

    revisions = load_package_version_changes(package.id, channel_filter)

    latest_updated =
      case revisions do
        [rev | _] -> rev.released_at
        [] -> DateTime.utc_now()
      end

    title =
      if channel_filter != "" do
        "#{name} on #{channel_filter} - Tracker"
      else
        "#{name} - Tracker"
      end

    self_url =
      if channel_filter != "" do
        "#{@base_url}/feeds/packages/#{name}?channel=#{channel_filter}"
      else
        "#{@base_url}/feeds/packages/#{name}"
      end

    feed =
      Atomex.Feed.new(
        "#{@base_url}/packages/#{name}",
        latest_updated,
        title
      )
      |> Atomex.Feed.link(self_url, rel: "self")
      |> Atomex.Feed.link("#{@base_url}/packages/#{name}", rel: "alternate")
      |> Atomex.Feed.entries(Enum.map(revisions, &package_entry(name, &1)))
      |> Atomex.Feed.build()
      |> Atomex.generate_document()

    conn
    |> put_resp_content_type("application/atom+xml")
    |> send_resp(200, feed)
  end

  defp channel_entry(channel, rev) do
    url = "#{@base_url}/channels/#{channel}/revisions/#{rev.revision}"
    short_hash = String.slice(rev.revision, 0, 7)

    Atomex.Entry.new(
      url,
      rev.released_at,
      "#{channel} #{short_hash}"
    )
    |> Atomex.Entry.link(url, rel: "alternate")
    |> Atomex.Entry.published(rev.released_at)
    |> Atomex.Entry.build()
  end

  defp package_entry(name, rev) do
    url = "#{@base_url}/channels/#{rev.channel_name}/revisions/#{rev.revision}"

    Atomex.Entry.new(
      "#{url}##{name}",
      rev.released_at,
      "#{name} #{rev.version} on #{rev.channel_name}"
    )
    |> Atomex.Entry.link(url, rel: "alternate")
    |> Atomex.Entry.published(rev.released_at)
    |> Atomex.Entry.summary("#{name} updated to #{rev.version} on #{rev.channel_name}")
    |> Atomex.Entry.build()
  end

  defp load_package_version_changes(package_id, channel_filter) do
    channel_id =
      if channel_filter != "" do
        case Tracker.Nixpkgs.Channel.by_name(channel_filter) do
          {:ok, ch} -> ch.id
          _ -> nil
        end
      end

    {results, _count} =
      Tracker.Nixpkgs.PackageRevision.version_changes_by_package(package_id,
        channel_id: channel_id,
        sort_by: :released_at,
        sort_dir: :desc,
        limit: 50
      )

    results
  end
end

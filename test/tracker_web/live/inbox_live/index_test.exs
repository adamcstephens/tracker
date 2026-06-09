defmodule TrackerWeb.InboxLive.IndexTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tracker.Fixtures

  alias AshAuthentication.Plug.Helpers
  alias Tracker.Notifications.Notification

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Helpers.store_in_session(user)
  end

  defp published_notification!(user, overrides \\ %{}) do
    chan = channel!("nixos-unstable")
    rev = channel_revision!(chan)

    notification!(
      user,
      Map.merge(
        %{type: :channel_revision_published, channel_id: chan.id, channel_revision_id: rev.id},
        overrides
      )
    )
  end

  test "redirects a logged-out visitor to sign in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/inbox")
  end

  test "shows an empty state when there are no notifications", %{conn: conn} do
    user = register_user!()
    conn = log_in(conn, user)

    {:ok, view, _html} = live(conn, ~p"/inbox")

    assert has_element?(view, "#inbox-empty")
  end

  test "lists the user's notifications", %{conn: conn} do
    user = register_user!()
    published_notification!(user)
    conn = log_in(conn, user)

    {:ok, view, _html} = live(conn, ~p"/inbox")

    assert has_element?(view, "#notifications")
    assert render(view) =~ "published on nixos-unstable"
  end

  test "does not show another user's notifications", %{conn: conn} do
    user = register_user!()
    other = register_user!()
    published_notification!(other)
    conn = log_in(conn, user)

    {:ok, view, _html} = live(conn, ~p"/inbox")

    assert has_element?(view, "#inbox-empty")
  end

  test "marks a single notification read", %{conn: conn} do
    user = register_user!()
    n = published_notification!(user)
    conn = log_in(conn, user)

    {:ok, view, _html} = live(conn, ~p"/inbox")
    assert has_element?(view, "#notification-#{n.id}.inbox-item--unread")

    view |> element("#notification-#{n.id} button", "Mark read") |> render_click()

    refute has_element?(view, "#notification-#{n.id}.inbox-item--unread")
    assert {:ok, %Notification{read_at: read_at}} = Ash.get(Notification, n.id, actor: user)
    refute is_nil(read_at)
  end

  test "marks all notifications read", %{conn: conn} do
    user = register_user!()
    published_notification!(user)
    published_notification!(user)
    conn = log_in(conn, user)

    {:ok, view, _html} = live(conn, ~p"/inbox")
    assert has_element?(view, "#mark-all-read")

    view |> element("#mark-all-read") |> render_click()

    refute has_element?(view, ".inbox-item--unread")
    refute has_element?(view, "#mark-all-read")
  end

  test "filters to a single channel revision", %{conn: conn} do
    user = register_user!()
    chan = channel!("nixos-unstable")
    rev = channel_revision!(chan)
    other_rev = channel_revision!(chan)

    notification!(user, %{
      type: :channel_revision_published,
      channel_id: chan.id,
      channel_revision_id: rev.id,
      occurred_at: ~U[2024-01-01 00:00:00Z]
    })

    kept =
      notification!(user, %{
        type: :channel_revision_published,
        channel_id: chan.id,
        channel_revision_id: other_rev.id,
        occurred_at: ~U[2024-02-01 00:00:00Z]
      })

    conn = log_in(conn, user)

    {:ok, view, _html} = live(conn, ~p"/inbox?channel_revision_id=#{other_rev.id}")

    assert has_element?(view, "#notification-#{kept.id}")
    assert view |> render() |> String.contains?("Show all")
  end

  test "links to the user's feed with a host-relative href", %{conn: conn} do
    user = register_user!()
    conn = log_in(conn, user)

    {:ok, view, _html} = live(conn, ~p"/inbox")

    # Relative path (starts with "/", not an absolute http URL) so it resolves
    # against the host the user actually visited.
    assert view |> element("#feed-link") |> render() =~ ~s(href="/feeds/notifications/trk_feed_)
  end

  test "regenerating the feed token invalidates the old URL", %{conn: conn} do
    user = register_user!()
    conn = log_in(conn, user)

    {:ok, view, _html} = live(conn, ~p"/inbox")
    old_token = Ash.get!(Tracker.Accounts.User, user.id, authorize?: false).feed_token
    refute is_nil(old_token)

    view |> element("#regenerate-feed-token") |> render_click()

    assert {:ok, nil} = Tracker.Accounts.User.by_feed_token(old_token, authorize?: false)
  end

  test "updates live when a notification is inserted", %{conn: conn} do
    user = register_user!()
    conn = log_in(conn, user)

    {:ok, view, _html} = live(conn, ~p"/inbox")
    assert has_element?(view, "#inbox-empty")

    published_notification!(user)

    refute has_element?(view, "#inbox-empty")
    assert render(view) =~ "published on nixos-unstable"
  end
end

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
    n = published_notification!(user)
    conn = log_in(conn, user)

    {:ok, view, _html} = live(conn, ~p"/inbox")

    assert has_element?(view, "#notification-#{n.id}")
    assert render(view) =~ "New revision"
  end

  test "does not show another user's notifications", %{conn: conn} do
    user = register_user!()
    other = register_user!()
    published_notification!(other)
    conn = log_in(conn, user)

    {:ok, view, _html} = live(conn, ~p"/inbox")

    assert has_element?(view, "#inbox-empty")
  end

  test "groups notifications by day", %{conn: conn} do
    user = register_user!()
    published_notification!(user, %{occurred_at: DateTime.utc_now(:second)})

    published_notification!(user, %{
      occurred_at: DateTime.utc_now(:second) |> DateTime.add(-1, :day)
    })

    conn = log_in(conn, user)

    {:ok, view, _html} = live(conn, ~p"/inbox")

    html = render(view)
    assert html =~ "Today"
    assert html =~ "Yesterday"
  end

  test "toggles a notification between read and unread", %{conn: conn} do
    user = register_user!()
    n = published_notification!(user)
    conn = log_in(conn, user)

    {:ok, view, _html} = live(conn, ~p"/inbox")
    assert has_element?(view, "#notification-#{n.id}.is-unread")

    view |> element("#notification-#{n.id} [aria-label='Mark as read']") |> render_click()

    refute has_element?(view, "#notification-#{n.id}.is-unread")
    assert {:ok, %Notification{read_at: read_at}} = Ash.get(Notification, n.id, actor: user)
    refute is_nil(read_at)

    view |> element("#notification-#{n.id} [aria-label='Mark as unread']") |> render_click()

    assert has_element?(view, "#notification-#{n.id}.is-unread")
    assert {:ok, %Notification{read_at: nil}} = Ash.get(Notification, n.id, actor: user)
  end

  test "marks all notifications read and disables the button", %{conn: conn} do
    user = register_user!()
    published_notification!(user)
    published_notification!(user)
    conn = log_in(conn, user)

    {:ok, view, _html} = live(conn, ~p"/inbox")
    refute has_element?(view, "#mark-all-read[disabled]")

    view |> element("#mark-all-read") |> render_click()

    refute has_element?(view, ".is-unread")
    assert has_element?(view, "#mark-all-read[disabled]")
  end

  test "filters to unread only", %{conn: conn} do
    user = register_user!()
    read = published_notification!(user)
    unread = published_notification!(user)
    {:ok, _} = Notification.mark_read(read, actor: user)
    conn = log_in(conn, user)

    {:ok, view, _html} = live(conn, ~p"/inbox")
    assert has_element?(view, "#notification-#{read.id}")

    view |> element("#filter-unread") |> render_click()

    refute has_element?(view, "#notification-#{read.id}")
    assert has_element?(view, "#notification-#{unread.id}")

    view |> element("#filter-all") |> render_click()
    assert has_element?(view, "#notification-#{read.id}")
  end

  test "filters by type with multi-select chips", %{conn: conn} do
    user = register_user!()
    revision = published_notification!(user)
    pkg = package!()
    chan = channel!()
    added = notification!(user, %{type: :package_added, package_id: pkg.id, channel_id: chan.id})
    conn = log_in(conn, user)

    {:ok, view, _html} = live(conn, ~p"/inbox")

    view |> element("#filter-type-package_added") |> render_click()

    assert has_element?(view, "#notification-#{added.id}")
    refute has_element?(view, "#notification-#{revision.id}")

    view |> element("#filter-type-channel_revision_published") |> render_click()
    assert has_element?(view, "#notification-#{revision.id}")

    # deselecting both shows everything again
    view |> element("#filter-type-package_added") |> render_click()
    view |> element("#filter-type-channel_revision_published") |> render_click()
    assert has_element?(view, "#notification-#{added.id}")
    assert has_element?(view, "#notification-#{revision.id}")
  end

  test "shows an empty-filter state when nothing matches", %{conn: conn} do
    user = register_user!()
    n = published_notification!(user)
    {:ok, _} = Notification.mark_read(n, actor: user)
    conn = log_in(conn, user)

    {:ok, view, _html} = live(conn, ~p"/inbox")
    view |> element("#filter-unread") |> render_click()

    assert render(view) =~ "Nothing matches these filters."
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

  test "links to the user's feed with a host-relative href from the overflow menu", %{conn: conn} do
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
    assert render(view) =~ "New revision"
  end

  describe "nav inbox icon" do
    test "the nav shows an inbox icon with the unread count instead of a text tab", %{conn: conn} do
      user = register_user!()
      published_notification!(user)
      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/packages")

      refute view |> element(".app-tabs") |> render() =~ "Inbox"
      assert has_element?(view, "#inbox-icon")
      assert view |> element("#inbox-icon .app-inbox__badge") |> render() =~ "1"
    end

    test "the badge is hidden at zero unread and the icon is active on the inbox page", %{
      conn: conn
    } do
      user = register_user!()
      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/inbox")

      refute has_element?(view, "#inbox-icon .app-inbox__badge")
      assert has_element?(view, "#inbox-icon[aria-current='page']")
    end

    test "no inbox icon for logged-out visitors", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/packages")

      refute has_element?(view, "#inbox-icon")
    end
  end
end

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
    chan = channel!()
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

  test "renders notifications through the shared RowList", %{conn: conn} do
    user = register_user!()
    n = published_notification!(user)
    conn = log_in(conn, user)

    {:ok, _view, html} = live(conn, ~p"/inbox")

    assert html =~ ~s(class="row-list")

    document = Floki.parse_document!(html)
    assert Floki.find(document, ".ibx-list") == []
    assert Floki.find(document, ".ibx-row") == []

    [row] = Floki.find(document, "#notification-#{n.id}")

    assert Floki.find(row, ".row-leading .ibx-glyph") != []
    assert Floki.find(row, ".row-label") != []
    assert Floki.find(row, ".row-sublabel time") != []
    # Read state and the per-type colour still ride on the row itself
    assert Floki.attribute(row, "class") == ["is-unread"]
    assert Floki.attribute(row, "style") == ["--type-color: var(--t-revision)"]
  end

  test "row actions stay in the trailing actions slot", %{conn: conn} do
    user = register_user!()
    n = published_notification!(user)
    conn = log_in(conn, user)

    {:ok, _view, html} = live(conn, ~p"/inbox")

    document = Floki.parse_document!(html)
    [actions] = Floki.find(document, "#notification-#{n.id} .row-actions")

    assert Floki.find(actions, ".ibx-unread-dot") != []
    assert Floki.find(actions, "[aria-label='Mark as read']") != []
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

  test "shows the view toggle with Inbox active", %{conn: conn} do
    user = register_user!()
    conn = log_in(conn, user)

    {:ok, view, _html} = live(conn, ~p"/inbox")

    assert has_element?(view, ~s{#view-nav-subscriptions[href="/inbox/subscriptions"]})
    assert has_element?(view, ~s{#view-nav-inbox.is-active[aria-current="page"]})
    refute has_element?(view, "#view-nav-subscriptions.is-active")
  end

  test "toggles a notification between read and unread", %{conn: conn} do
    user = register_user!()
    n = published_notification!(user)
    conn = log_in(conn, user)

    {:ok, view, _html} = live(conn, ~p"/inbox")
    # widen to All so the row stays visible once it is read
    view |> element("#filter-all") |> render_click()
    assert has_element?(view, "#notification-#{n.id}.is-unread")

    view |> element("#notification-#{n.id} [aria-label='Mark as read']") |> render_click()

    refute has_element?(view, "#notification-#{n.id}.is-unread")
    assert {:ok, %Notification{read_at: read_at}} = Ash.get(Notification, n.id, actor: user)
    refute is_nil(read_at)

    view |> element("#notification-#{n.id} [aria-label='Mark as unread']") |> render_click()

    assert has_element?(view, "#notification-#{n.id}.is-unread")
    assert {:ok, %Notification{read_at: nil}} = Ash.get(Notification, n.id, actor: user)
  end

  # The "m" handler in assets/js/ui.js reaches the toggle through these
  # selectors, and steps the cursor off the row only in the Unread segment.
  # Nothing but this stops the markup drifting out from under it.
  describe "the markup the m shortcut selects (TRK-393)" do
    test "the toggle is a phx-click button inside a keyed row-list item", %{conn: conn} do
      user = register_user!()
      n = published_notification!(user)
      conn = log_in(conn, user)

      {:ok, _view, html} = live(conn, ~p"/inbox")

      [row] =
        html
        |> Floki.parse_document!()
        |> Floki.find("ul.row-list > li#notification-#{n.id}")

      assert Floki.find(row, "button[phx-click='toggle-read']") != []
    end

    test "the Unread segment marks itself active, and All does not", %{conn: conn} do
      user = register_user!()
      published_notification!(user)
      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/inbox")

      assert has_element?(view, "#filter-unread.is-active")

      view |> element("#filter-all") |> render_click()

      refute has_element?(view, "#filter-unread.is-active")
    end
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

  test "defaults to unread only and can widen to all", %{conn: conn} do
    user = register_user!()
    read = published_notification!(user)
    unread = published_notification!(user)
    {:ok, _} = Notification.mark_read(read, actor: user)
    conn = log_in(conn, user)

    {:ok, view, _html} = live(conn, ~p"/inbox")

    refute has_element?(view, "#notification-#{read.id}")
    assert has_element?(view, "#notification-#{unread.id}")

    view |> element("#filter-all") |> render_click()
    assert has_element?(view, "#notification-#{read.id}")

    view |> element("#filter-unread") |> render_click()
    refute has_element?(view, "#notification-#{read.id}")
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

  test "shows the version bump for package_version_changed notifications", %{conn: conn} do
    user = register_user!()
    pkg = package!()
    chan = channel!()
    prev = channel_revision!(chan, %{released_at: ~U[2026-02-01 00:00:00Z]})

    rev =
      channel_revision!(chan, %{
        previous_channel_revision_id: prev.id,
        released_at: ~U[2026-02-02 00:00:00Z]
      })

    apply_package_revision!(prev, [{pkg, "9.0"}])
    apply_package_revision!(rev, [{pkg, "9.1"}])

    n =
      notification!(user, %{
        type: :package_version_changed,
        package_id: pkg.id,
        channel_id: chan.id,
        channel_revision_id: rev.id
      })

    conn = log_in(conn, user)

    {:ok, view, _html} = live(conn, ~p"/inbox")

    assert view |> element("#notification-#{n.id}") |> render() =~
             "#{pkg.attribute} 9.0 → 9.1"
  end

  test "shows the version bump for a read notification after widening to All", %{conn: conn} do
    user = register_user!()
    pkg = package!()
    chan = channel!()
    prev = channel_revision!(chan, %{released_at: ~U[2026-02-01 00:00:00Z]})

    rev =
      channel_revision!(chan, %{
        previous_channel_revision_id: prev.id,
        released_at: ~U[2026-02-02 00:00:00Z]
      })

    apply_package_revision!(prev, [{pkg, "3.2"}])
    apply_package_revision!(rev, [{pkg, "3.3"}])

    n =
      notification!(user, %{
        type: :package_version_changed,
        package_id: pkg.id,
        channel_id: chan.id,
        channel_revision_id: rev.id
      })

    {:ok, _} = Notification.mark_read(n, actor: user)
    conn = log_in(conn, user)

    {:ok, view, _html} = live(conn, ~p"/inbox")
    refute has_element?(view, "#notification-#{n.id}")

    view |> element("#filter-all") |> render_click()

    assert view |> element("#notification-#{n.id}") |> render() =~ "#{pkg.attribute} 3.2 → 3.3"
  end

  test "type chip counts reflect the unread/all selection", %{conn: conn} do
    user = register_user!()
    read = published_notification!(user)
    _unread = published_notification!(user)
    {:ok, _} = Notification.mark_read(read, actor: user)
    conn = log_in(conn, user)

    {:ok, view, _html} = live(conn, ~p"/inbox")

    assert view |> element("#filter-type-channel_revision_published .n") |> render() =~ ">1<"

    view |> element("#filter-all") |> render_click()

    assert view |> element("#filter-type-channel_revision_published .n") |> render() =~ ">2<"

    view |> element("#filter-unread") |> render_click()

    assert view |> element("#filter-type-channel_revision_published .n") |> render() =~ ">1<"
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
    chan = channel!()
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

  test "exposes the feed as a copy-on-click icon with a host-relative href", %{conn: conn} do
    user = register_user!()
    conn = log_in(conn, user)

    {:ok, view, _html} = live(conn, ~p"/inbox")

    feed = view |> element("#feed-link") |> render()
    # Relative path (starts with "/", not an absolute http URL) so it resolves
    # against the host the user actually visited.
    assert feed =~ ~s(href="/feeds/notifications/trk_feed_)
    # Copy-on-click for JS users; right-click "copy link" still works via the href.
    assert feed =~ ~s(phx-hook="CopyLink")
  end

  test "no longer offers token regeneration from the inbox", %{conn: conn} do
    user = register_user!()
    conn = log_in(conn, user)

    {:ok, view, _html} = live(conn, ~p"/inbox")

    refute has_element?(view, "#regenerate-feed-token")
    refute has_element?(view, "#inbox-menu")
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

  describe "live navigation" do
    test "live-navigates between the inbox and other tabs in one session", %{conn: conn} do
      user = register_user!()
      conn = log_in(conn, user)

      {:ok, packages, _html} = live(conn, ~p"/packages")
      assert {:ok, inbox, _html} = live_redirect(packages, to: ~p"/inbox")
      assert {:ok, _packages, _html} = live_redirect(inbox, to: ~p"/packages")
    end
  end

  describe "search bar and lens" do
    test "renders the lens with its selector disabled", %{conn: conn} do
      user = register_user!()
      channel!()
      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/inbox")

      assert has_element?(view, "#lens select.lens__select[disabled]")
    end

    test "renders an active search box", %{conn: conn} do
      user = register_user!()
      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/inbox")

      assert has_element?(view, "#page-search-input")
      refute has_element?(view, "#page-search-input[disabled]")
    end

    test "search filters notifications and scopes the type chip counts", %{conn: conn} do
      user = register_user!()
      chan = channel!()

      firefox =
        notification!(user, %{
          type: :package_added,
          package_id: package!("firefox-#{System.unique_integer([:positive])}").id,
          channel_id: chan.id
        })

      vim =
        notification!(user, %{
          type: :package_added,
          package_id: package!().id,
          channel_id: chan.id
        })

      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/inbox")

      view |> element("#page-search") |> render_change(%{"search" => "FIRE"})

      assert has_element?(view, "#notification-#{firefox.id}")
      refute has_element?(view, "#notification-#{vim.id}")
      assert view |> element("#filter-type-package_added .n") |> render() =~ ">1<"
    end

    test "search matches the channel name", %{conn: conn} do
      user = register_user!()
      chan = channel!()

      n =
        notification!(user, %{
          type: :package_added,
          package_id: package!().id,
          channel_id: chan.id
        })

      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/inbox")

      view |> element("#page-search") |> render_change(%{"search" => chan.name})
      assert has_element?(view, "#notification-#{n.id}")

      view |> element("#page-search") |> render_change(%{"search" => "nomatch"})
      refute has_element?(view, "#notification-#{n.id}")
    end

    test "applies the search param from the URL", %{conn: conn} do
      user = register_user!()
      chan = channel!()

      firefox =
        notification!(user, %{
          type: :package_added,
          package_id: package!("firefox-#{System.unique_integer([:positive])}").id,
          channel_id: chan.id
        })

      vim =
        notification!(user, %{
          type: :package_added,
          package_id: package!().id,
          channel_id: chan.id
        })

      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/inbox?search=firefox")

      assert has_element?(view, "#notification-#{firefox.id}")
      refute has_element?(view, "#notification-#{vim.id}")
      assert has_element?(view, "#page-search-input[value='firefox']")
    end
  end
end

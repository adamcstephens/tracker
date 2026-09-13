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

  defp notifications!(user, count, overrides \\ %{}) do
    chan = channel!()
    rev = channel_revision!(chan)

    rows =
      for i <- 1..count do
        Map.merge(
          %{
            user_id: user.id,
            type: :channel_revision_published,
            channel_id: chan.id,
            channel_revision_id: rev.id,
            occurred_at: DateTime.add(~U[2024-01-01 00:00:00Z], i, :minute),
            dedup_key: "dk-#{System.unique_integer([:positive])}"
          },
          overrides
        )
      end

    :ok = Notification.fanout(rows)

    Notification.for_user!(actor: user)
  end

  defp notification_row_ids(view) do
    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.find("#inbox-groups ul.row-list > li")
    |> Floki.attribute("id")
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

  describe "read segments" do
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

  describe "cross-device sync" do
    test "marking read on one session updates another", %{conn: conn} do
      user = register_user!()
      published_notification!(user)
      conn = log_in(conn, user)

      {:ok, phone, _} = live(conn, ~p"/inbox?filter=all")
      {:ok, laptop, _} = live(conn, ~p"/inbox?filter=all")

      assert has_element?(laptop, ".is-unread")

      phone |> element("button[phx-click='toggle-read']") |> render_click()

      refute render(laptop) =~ "is-unread"
    end

    test "marking unread on one session updates another", %{conn: conn} do
      user = register_user!()
      n = published_notification!(user)
      {:ok, _} = Notification.mark_read(n, actor: user)
      conn = log_in(conn, user)

      {:ok, phone, _} = live(conn, ~p"/inbox?filter=all")
      {:ok, laptop, _} = live(conn, ~p"/inbox?filter=all")

      refute render(laptop) =~ "is-unread"

      phone |> element("button[phx-click='toggle-read']") |> render_click()

      assert has_element?(laptop, ".is-unread")
    end

    test "mark-all-read on one session updates another", %{conn: conn} do
      user = register_user!()
      published_notification!(user)
      published_notification!(user)
      conn = log_in(conn, user)

      {:ok, phone, _} = live(conn, ~p"/inbox?filter=all")
      {:ok, laptop, _} = live(conn, ~p"/inbox?filter=all")

      assert has_element?(laptop, ".is-unread")

      phone |> element("#mark-all-read") |> render_click()

      refute render(laptop) =~ "is-unread"
    end
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

  describe "Saved" do
    test "saving persists without changing read state and read toggles preserve saved state", %{
      conn: conn
    } do
      user = register_user!()
      n = published_notification!(user)
      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/inbox")

      view
      |> element(
        "#notification-#{n.id} button[aria-label='Save for later'][aria-pressed='false']"
      )
      |> render_click()

      assert has_element?(view, "#notification-#{n.id}.is-unread")
      assert %Notification{saved: true, read_at: nil} = Ash.get!(Notification, n.id, actor: user)
      assert view |> element("#filter-saved .n") |> render() =~ ">1<"
      assert view |> element("#filter-unread .n") |> render() =~ ">1<"
      assert view |> element("#inbox-icon .app-inbox__badge") |> render() =~ ">1<"

      {:ok, view, _html} = live(conn, ~p"/inbox?filter=saved")

      assert has_element?(view, "#filter-saved.is-active")

      assert has_element?(
               view,
               "#notification-#{n.id} button[aria-label='Remove from saved'][aria-pressed='true']"
             )

      view |> element("#notification-#{n.id} [aria-label='Mark as read']") |> render_click()

      assert has_element?(view, "#notification-#{n.id}:not(.is-unread)")

      assert %Notification{saved: true, read_at: read_at} =
               Ash.get!(Notification, n.id, actor: user)

      refute is_nil(read_at)
      refute has_element?(view, "#inbox-icon .app-inbox__badge")

      view |> element("#filter-all") |> render_click()
      view |> element("#notification-#{n.id} [aria-label='Remove from saved']") |> render_click()

      assert %Notification{saved: false, read_at: ^read_at} =
               Ash.get!(Notification, n.id, actor: user)

      view |> element("#notification-#{n.id} [aria-label='Save for later']") |> render_click()
      view |> element("#notification-#{n.id} [aria-label='Mark as unread']") |> render_click()

      assert %Notification{saved: true, read_at: nil} = Ash.get!(Notification, n.id, actor: user)

      view |> element("#notification-#{n.id} [aria-label='Remove from saved']") |> render_click()

      {:ok, reloaded, _html} = live(conn, ~p"/inbox?filter=all")

      assert has_element?(
               reloaded,
               "#notification-#{n.id}.is-unread button[aria-label='Save for later'][aria-pressed='false']"
             )

      assert %Notification{saved: false, read_at: nil} = Ash.get!(Notification, n.id, actor: user)
      assert reloaded |> element("#filter-saved .n") |> render() =~ ">0<"
    end

    test "Saved counts ignore search and types while rows and type counts compose with revision",
         %{
           conn: conn
         } do
      user = register_user!()
      chan = channel!()
      rev = channel_revision!(chan)
      other_rev = channel_revision!(chan)
      needle = package!("needle-#{System.unique_integer([:positive])}")
      haystack = package!()

      attrs = %{
        type: :package_added,
        package_id: needle.id,
        channel_id: chan.id,
        channel_revision_id: rev.id
      }

      saved_unread = notification!(user, attrs) |> Notification.save!(actor: user)

      saved_read =
        notification!(user, attrs)
        |> Notification.save!(actor: user)
        |> Notification.mark_read!(actor: user)

      saved_removed =
        notification!(user, %{attrs | type: :package_removed})
        |> Notification.save!(actor: user)

      outside_search =
        notification!(user, %{attrs | package_id: haystack.id})
        |> Notification.save!(actor: user)

      outside_revision =
        notification!(user, %{attrs | channel_revision_id: other_rev.id})
        |> Notification.save!(actor: user)

      unsaved = notification!(user, attrs)
      other_user = register_user!()
      other_saved = notification!(other_user, attrs) |> Notification.save!(actor: other_user)
      conn = log_in(conn, user)

      {:ok, view, _html} =
        live(
          conn,
          ~p"/inbox?filter=saved&search=needle&types=package_added&channel_revision_id=#{rev.id}"
        )

      assert has_element?(view, "#notification-#{saved_unread.id}.is-unread")
      assert has_element?(view, "#notification-#{saved_read.id}:not(.is-unread)")

      for n <- [saved_removed, outside_search, outside_revision, unsaved, other_saved] do
        refute has_element?(view, "#notification-#{n.id}")
      end

      assert view |> element("#filter-saved .n") |> render() =~ ">4<"
      assert view |> element("#filter-all .n") |> render() =~ ">5<"
      assert view |> element("#filter-unread .n") |> render() =~ ">4<"
      assert view |> element("#filter-type-package_added .n") |> render() =~ ">2<"
      assert view |> element("#filter-type-package_removed .n") |> render() =~ ">1<"

      view |> element("#filter-type-package_removed") |> render_click()

      assert has_element?(view, "#notification-#{saved_removed.id}")
      assert has_element?(view, "#notification-#{saved_read.id}")
      assert view |> element("#filter-saved .n") |> render() =~ ">4<"

      view |> element("#page-search") |> render_change(%{"search" => haystack.attribute})

      assert notification_row_ids(view) == ["notification-#{outside_search.id}"]
      assert has_element?(view, "#filter-saved.is-active")
      assert has_element?(view, "#filter-type-package_added.is-active")
      assert has_element?(view, "#filter-type-package_removed.is-active")
      assert view |> element("#filter-saved .n") |> render() =~ ">4<"
      assert view |> element("#filter-type-package_added .n") |> render() =~ ">1<"
      assert view |> element("#filter-type-package_removed .n") |> render() =~ ">0<"

      view |> element("#page-search") |> render_change(%{"search" => "needle"})
      view |> element("#filter-all") |> render_click()

      assert has_element?(view, "#notification-#{unsaved.id}")
      refute has_element?(view, "#notification-#{outside_revision.id}")
      assert view |> element("#filter-saved .n") |> render() =~ ">4<"
      assert view |> element("#filter-type-package_added .n") |> render() =~ ">3<"
    end

    test "saved pages keep tied timestamps stable and removing the last page clamps the URL", %{
      conn: conn
    } do
      user = register_user!()

      saved =
        user
        |> notifications!(51, %{occurred_at: ~U[2024-01-01 00:00:00Z]})
        |> Enum.map(&Notification.save!(&1, actor: user))
        |> Enum.sort_by(& &1.id, :desc)

      [newest | _] = saved
      last = List.last(saved)
      conn = log_in(conn, user)

      params = %{
        filter: "saved",
        search: newest.channel.name,
        types: "channel_revision_published",
        channel_revision_id: newest.channel_revision_id
      }

      {:ok, view, _html} = live(conn, ~p"/inbox?#{params}")
      first_page = saved |> Enum.take(25) |> Enum.map(&"notification-#{&1.id}")
      second_page = saved |> Enum.slice(25, 25) |> Enum.map(&"notification-#{&1.id}")

      assert notification_row_ids(view) == first_page
      assert view |> element("#filter-saved .n") |> render() =~ ">51<"
      assert view |> element("#filter-type-channel_revision_published .n") |> render() =~ ">51<"

      view |> element("#pagination-inbox-groups a", "→") |> render_click()
      assert_patch(view)
      assert notification_row_ids(view) == second_page

      view |> element("#pagination-inbox-groups a", "→") |> render_click()
      assert_patch(view)
      assert notification_row_ids(view) == ["notification-#{last.id}"]

      view
      |> element("#notification-#{last.id} [aria-label='Remove from saved']")
      |> render_click()

      assert_push_event(view, "update-url", %{path: path})
      query = path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert query["page"] == "2"
      assert query["filter"] == "saved"
      assert query["search"] == newest.channel.name
      assert query["types"] == "channel_revision_published"
      assert query["channel_revision_id"] == to_string(newest.channel_revision_id)
      assert notification_row_ids(view) == second_page
      assert view |> element("#filter-saved .n") |> render() =~ ">50<"

      assert %Notification{saved: false, read_at: nil} =
               Ash.get!(Notification, last.id, actor: user)

      {:ok, reloaded, _html} = live(conn, path)
      assert notification_row_ids(reloaded) == second_page

      reloaded |> element("#pagination-inbox-groups a", "←") |> render_click()
      assert notification_row_ids(reloaded) == first_page
    end

    test "removing the final saved row leaves an empty Saved view without deleting notifications",
         %{
           conn: conn
         } do
      user = register_user!()
      saved = published_notification!(user) |> Notification.save!(actor: user)
      unsaved = published_notification!(user)
      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/inbox?filter=saved")

      view
      |> element("#notification-#{saved.id} [aria-label='Remove from saved']")
      |> render_click()

      assert has_element?(view, "#filter-saved.is-active")
      assert has_element?(view, ".ibx-empty")
      assert has_element?(view, "#mark-all-read[disabled]")
      assert notification_row_ids(view) == []
      assert view |> element("#filter-saved .n") |> render() =~ ">0<"
      assert view |> element("#filter-all .n") |> render() =~ ">2<"
      assert view |> element("#filter-unread .n") |> render() =~ ">2<"

      view |> element("#filter-all") |> render_click()

      assert has_element?(view, "#notification-#{saved.id}.is-unread")
      assert has_element?(view, "#notification-#{unsaved.id}.is-unread")
    end

    test "save and unsave synchronize connected sessions without changing the unread badge", %{
      conn: conn
    } do
      user = register_user!()
      n = published_notification!(user)
      conn = log_in(conn, user)

      {:ok, phone, _html} = live(conn, ~p"/inbox?filter=all")
      {:ok, laptop, _html} = live(conn, ~p"/inbox?filter=saved")
      {:ok, packages, _html} = live(conn, ~p"/packages")

      assert has_element?(laptop, ".ibx-empty")
      assert packages |> element("#inbox-icon .app-inbox__badge") |> render() =~ ">1<"

      phone |> element("#notification-#{n.id} [aria-label='Save for later']") |> render_click()

      assert has_element?(laptop, "#notification-#{n.id}.is-unread")

      assert has_element?(
               laptop,
               "#notification-#{n.id} button[aria-label='Remove from saved'][aria-pressed='true']"
             )

      assert laptop |> element("#filter-saved .n") |> render() =~ ">1<"
      assert laptop |> element("#filter-unread .n") |> render() =~ ">1<"
      assert packages |> element("#inbox-icon .app-inbox__badge") |> render() =~ ">1<"

      phone |> element("#notification-#{n.id} [aria-label='Mark as read']") |> render_click()

      assert has_element?(laptop, "#notification-#{n.id}:not(.is-unread)")
      assert laptop |> element("#filter-saved .n") |> render() =~ ">1<"
      refute has_element?(laptop, "#inbox-icon .app-inbox__badge")
      refute has_element?(packages, "#inbox-icon .app-inbox__badge")

      phone |> element("#notification-#{n.id} [aria-label='Remove from saved']") |> render_click()

      refute has_element?(laptop, "#notification-#{n.id}")
      assert has_element?(laptop, ".ibx-empty")
      assert laptop |> element("#filter-saved .n") |> render() =~ ">0<"
      refute has_element?(packages, "#inbox-icon .app-inbox__badge")

      phone |> element("#notification-#{n.id} [aria-label='Save for later']") |> render_click()
      assert has_element?(laptop, "#notification-#{n.id}:not(.is-unread)")
      refute has_element?(packages, "#inbox-icon .app-inbox__badge")

      laptop
      |> element("#notification-#{n.id} [aria-label='Remove from saved']")
      |> render_click()

      assert has_element?(
               phone,
               "#notification-#{n.id} button[aria-label='Save for later'][aria-pressed='false']"
             )

      assert phone |> element("#filter-saved .n") |> render() =~ ">0<"
    end

    test "Mark all read honors Saved, search, types and revision across every matching page", %{
      conn: conn
    } do
      user = register_user!()
      chan = channel!()
      rev = channel_revision!(chan)
      needle = package!("needle-#{System.unique_integer([:positive])}")

      attrs = %{
        type: :package_added,
        package_id: needle.id,
        channel_id: chan.id,
        channel_revision_id: rev.id
      }

      matching =
        user
        |> notifications!(30, attrs)
        |> Enum.map(&Notification.save!(&1, actor: user))

      removed =
        notification!(user, %{attrs | type: :package_removed})
        |> Notification.save!(actor: user)

      already_read =
        notification!(user, attrs)
        |> Notification.save!(actor: user)
        |> Notification.mark_read!(actor: user)

      unsaved = notification!(user, attrs)

      outside_search =
        notification!(user, %{attrs | package_id: package!().id})
        |> Notification.save!(actor: user)

      outside_type =
        notification!(user, %{attrs | type: :channel_revision_published})
        |> Notification.save!(actor: user)

      outside_revision =
        notification!(user, %{attrs | channel_revision_id: channel_revision!(chan).id})
        |> Notification.save!(actor: user)

      other_user = register_user!()
      other_saved = notification!(other_user, attrs) |> Notification.save!(actor: other_user)
      conn = log_in(conn, user)

      {:ok, view, _html} =
        live(
          conn,
          ~p"/inbox?filter=saved&search=needle&types=package_added,package_removed&channel_revision_id=#{rev.id}&page=2"
        )

      refute has_element?(view, "#mark-all-read[disabled]")

      view |> element("#mark-all-read") |> render_click()

      assert has_element?(view, "#mark-all-read[disabled]")
      refute has_element?(view, "#inbox-groups .is-unread")

      for n <- [removed | matching] do
        assert %Notification{saved: true, read_at: read_at} =
                 Ash.get!(Notification, n.id, actor: user)

        refute is_nil(read_at)
      end

      assert Ash.get!(Notification, already_read.id, actor: user).read_at == already_read.read_at

      unread_ids =
        Notification.for_user!(%{unread_only: true}, actor: user)
        |> Enum.map(& &1.id)
        |> Enum.sort()

      assert unread_ids ==
               Enum.sort([unsaved.id, outside_search.id, outside_type.id, outside_revision.id])

      assert %Notification{saved: true, read_at: nil} =
               Ash.get!(Notification, other_saved.id, actor: other_user)

      assert view |> element("#filter-unread .n") |> render() =~ ">3<"
      assert view |> element("#inbox-icon .app-inbox__badge") |> render() =~ ">4<"
    end

    test "Mark all read is disabled when search, types or Saved exclude all unread rows", %{
      conn: conn
    } do
      user = register_user!()
      unread = published_notification!(user)

      saved_read =
        published_notification!(user)
        |> Notification.save!(actor: user)
        |> Notification.mark_read!(actor: user)

      conn = log_in(conn, user)
      {:ok, view, _html} = live(conn, ~p"/inbox?filter=all&search=no-match")

      assert has_element?(view, "#mark-all-read[disabled]")

      view |> element("#page-search") |> render_change(%{"search" => ""})
      refute has_element?(view, "#mark-all-read[disabled]")

      view |> element("#filter-type-package_added") |> render_click()
      assert has_element?(view, "#mark-all-read[disabled]")

      view |> element("#filter-type-package_added") |> render_click()
      view |> element("#filter-saved") |> render_click()

      assert has_element?(view, "#notification-#{saved_read.id}")
      assert has_element?(view, "#mark-all-read[disabled]")
      refute has_element?(view, "#notification-#{unread.id}")
      assert %Notification{read_at: nil} = Ash.get!(Notification, unread.id, actor: user)

      view |> element("#filter-unread") |> render_click()

      refute has_element?(view, "#mark-all-read[disabled]")
      assert has_element?(view, "#notification-#{unread.id}")
    end
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

  test "a PR notification leads with the change title and tags the package", %{conn: conn} do
    user = register_user!()
    pkg = package!("ripgrep")
    chan = channel!()
    change = change!(nil, %{state: :open, title: "ripgrep: 14.1.0 -> 14.1.1"})

    n =
      notification!(user, %{
        type: :package_change_opened,
        package_id: pkg.id,
        channel_id: chan.id,
        change_id: change.id
      })

    conn = log_in(conn, user)

    {:ok, _view, html} = live(conn, ~p"/inbox")

    [row] = html |> Floki.parse_document!() |> Floki.find("#notification-#{n.id}")

    assert row |> Floki.find(".row-label .ibx-title") |> Floki.text() =~ change.title
    assert row |> Floki.find(".row-sublabel .ibx-tag--package") |> Floki.text() =~ pkg.attribute
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

    assert has_element?(view, ".ibx-empty")
    refute has_element?(view, "#inbox-groups ul.row-list > li")
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

    test "the badge updates live on a non-inbox page when a notification arrives", %{conn: conn} do
      user = register_user!()
      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/packages")
      refute has_element?(view, "#inbox-icon .app-inbox__badge")

      published_notification!(user)

      assert render(view) =~ "app-inbox__badge"
    end

    test "the badge updates live on a non-inbox page when read elsewhere", %{conn: conn} do
      user = register_user!()
      n = published_notification!(user)
      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/packages")
      assert view |> element("#inbox-icon .app-inbox__badge") |> render() =~ "1"

      {:ok, _} = Notification.mark_read(n, actor: user)

      refute render(view) =~ "app-inbox__badge"
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

    test "search matches the package attribute on a PR notification", %{conn: conn} do
      user = register_user!()
      pkg = package!("firefox-#{System.unique_integer([:positive])}")
      change = change!(nil, %{state: :open, title: "no package name here"})

      n =
        notification!(user, %{
          type: :package_change_opened,
          package_id: pkg.id,
          change_id: change.id
        })

      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/inbox")

      view |> element("#page-search") |> render_change(%{"search" => "FIRE"})
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

  describe "pagination" do
    test "shows 25 notifications a page with controls to the next", %{conn: conn} do
      user = register_user!()
      [newest | _] = all = notifications!(user, 30)
      twenty_sixth = Enum.at(all, 25)
      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/inbox")

      assert has_element?(view, "#notification-#{newest.id}")
      refute has_element?(view, "#notification-#{twenty_sixth.id}")
      assert view |> render() =~ "Page 1 of 2"

      {:ok, view, _html} = live(conn, ~p"/inbox?page=2")

      refute has_element?(view, "#notification-#{newest.id}")
      assert has_element?(view, "#notification-#{twenty_sixth.id}")
      assert view |> render() =~ "Page 2 of 2"
    end

    test "the segment and chip counts cover every page", %{conn: conn} do
      user = register_user!()
      notifications!(user, 30)
      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/inbox")

      assert view |> element("#filter-unread .n") |> render() =~ ">30<"
      assert view |> element("#filter-all .n") |> render() =~ ">30<"

      assert view |> element("#filter-type-channel_revision_published .n") |> render() =~ ">30<"
    end

    test "search reaches notifications on later pages", %{conn: conn} do
      user = register_user!()
      notifications!(user, 30)
      pkg = package!("firefox-#{System.unique_integer([:positive])}")
      chan = channel!()

      firefox =
        notification!(user, %{
          type: :package_added,
          package_id: pkg.id,
          channel_id: chan.id,
          occurred_at: ~U[2023-01-01 00:00:00Z]
        })

      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/inbox")
      refute has_element?(view, "#notification-#{firefox.id}")

      view |> element("#page-search") |> render_change(%{"search" => "FIRE"})

      assert has_element?(view, "#notification-#{firefox.id}")
    end

    test "a type filter reaches notifications on later pages", %{conn: conn} do
      user = register_user!()
      notifications!(user, 30)
      chan = channel!()

      added =
        notification!(user, %{
          type: :package_added,
          package_id: package!().id,
          channel_id: chan.id,
          occurred_at: ~U[2023-01-01 00:00:00Z]
        })

      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/inbox")
      refute has_element?(view, "#notification-#{added.id}")

      view |> element("#filter-type-package_added") |> render_click()

      assert has_element?(view, "#notification-#{added.id}")
    end

    test "changing a filter returns to the first page", %{conn: conn} do
      user = register_user!()
      [newest | _] = notifications!(user, 30)
      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/inbox?page=2")
      refute has_element?(view, "#notification-#{newest.id}")

      view |> element("#filter-all") |> render_click()

      assert has_element?(view, "#notification-#{newest.id}")
      assert render(view) =~ "Page 1 of 2"
    end

    test "mark all read clears notifications beyond the current page", %{conn: conn} do
      user = register_user!()
      notifications!(user, 30)
      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/inbox")

      view |> element("#mark-all-read") |> render_click()

      assert has_element?(view, "#mark-all-read[disabled]")
      assert view |> element("#filter-unread .n") |> render() =~ ">0<"
      assert [] = Notification.for_user!(%{unread_only: true}, actor: user)
    end

    test "the search form carries the segment but resets the page", %{conn: conn} do
      user = register_user!()
      notifications!(user, 30)
      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/inbox?filter=all&page=2")

      assert has_element?(
               view,
               ~s{form#page-search input[type="hidden"][name="filter"][value="all"]}
             )

      refute has_element?(view, ~s{form#page-search input[type="hidden"][name="page"]})
    end
  end
end

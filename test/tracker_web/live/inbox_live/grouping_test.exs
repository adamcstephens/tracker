defmodule TrackerWeb.InboxLive.GroupingTest do
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

  defp revision_notifications!(user, count) do
    channel = channel!()
    revision = channel_revision!(channel)

    notifications =
      for _ <- 1..count do
        package = package!()

        notification!(user, %{
          type: :package_added,
          package_id: package.id,
          channel_id: channel.id,
          channel_revision_id: revision.id
        })
      end

    {revision, notifications}
  end

  defp group_counts(view, revision, notifications, packages, unread) do
    assert has_element?(
             view,
             "#revision-group-#{revision.id}[data-notification-count='#{notifications}']" <>
               "[data-package-count='#{packages}'][data-unread-count='#{unread}']"
           )
  end

  defp group_rows(view, revision) do
    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.find("#revision-group-#{revision.id} .notification-row")
    |> Floki.attribute("id")
  end

  defp assert_query(path, expected) do
    query = URI.decode_query(URI.parse(path).query || "")

    for {key, value} <- expected do
      assert query[to_string(key)] == to_string(value)
    end

    query
  end

  @tag :pr_grouping
  test "one PR row shows every package and toggles read and saved state for the displayed group",
       %{conn: conn} do
    user = register_user!()
    other = register_user!()
    change = change!()
    packages = for _ <- 1..3, do: package!()

    notifications =
      for package <- packages do
        notification!(user, %{
          type: :package_change_opened,
          change_id: change.id,
          package_id: package.id
        })
      end

    [first | _] = notifications
    Notification.mark_read!(first, actor: user)
    Notification.save!(first, actor: user)

    merged =
      notification!(user, %{
        type: :package_change_merged,
        change_id: change.id,
        package_id: hd(packages).id
      })

    outsider =
      notification!(other, %{
        type: :package_change_opened,
        change_id: change.id,
        package_id: hd(packages).id
      })

    {:ok, view, _html} = live(log_in(conn, user), ~p"/inbox?filter=all")
    row = "#notification-#{List.last(notifications).id}"

    assert view
           |> render()
           |> Floki.parse_document!()
           |> Floki.find(".notification-row")
           |> length() == 2

    assert has_element?(view, "#{row}.is-unread")

    for package <- packages do
      assert has_element?(
               view,
               "#{row} a[href='/packages/#{package.attribute}']",
               package.attribute
             )
    end

    view |> element("#{row} [aria-label='Mark as read']") |> render_click()
    assert has_element?(view, "#{row}.is-read")
    ids = Enum.map(notifications, & &1.id)

    assert Enum.all?(
             Notification.for_user!(actor: user),
             &(&1.id not in ids or &1.read_at != nil)
           )

    view |> element("#{row} [aria-label='Mark as unread']") |> render_click()
    assert Enum.all?(Notification.for_user!(actor: user), &is_nil(&1.read_at))

    view |> element("#{row} [aria-label='Save for later']") |> render_click()
    assert has_element?(view, "#{row} [aria-label='Remove from saved'][aria-pressed=true]")
    assert Enum.all?(Notification.for_user!(actor: user), &(&1.id not in ids or &1.saved))

    view |> element("#{row} [aria-label='Remove from saved']") |> render_click()
    assert Enum.all?(Notification.for_user!(actor: user), &(not &1.saved))
    assert Enum.find(Notification.for_user!(actor: user), &(&1.id == merged.id)).read_at == nil
    assert [%{id: outsider_id, read_at: nil, saved: false}] = Notification.for_user!(actor: other)
    assert outsider_id == outsider.id
  end

  @tag :pr_grouping
  test "PR group actions leave search-hidden packages unchanged", %{conn: conn} do
    user = register_user!()
    change = change!()
    package = package!()

    visible =
      notification!(user, %{
        type: :package_change_opened,
        change_id: change.id,
        package_id: package.id
      })

    hidden =
      notification!(user, %{
        type: :package_change_opened,
        change_id: change.id,
        package_id: package!().id
      })

    {:ok, view, _html} =
      live(log_in(conn, user), ~p"/inbox?filter=all&search=#{package.attribute}")

    row = "#notification-#{visible.id}"
    view |> element("#{row} [aria-label='Save for later']") |> render_click()
    view |> element("#{row} [aria-label='Mark as read']") |> render_click()
    notifications = Notification.for_user!(actor: user)
    assert %{read_at: nil, saved: false} = Enum.find(notifications, &(&1.id == hidden.id))
    assert %{read_at: %DateTime{}, saved: true} = Enum.find(notifications, &(&1.id == visible.id))
  end

  @tag :selected_a
  test "Inbox and Subscriptions share the wide heading and navigation shell", %{conn: conn} do
    user = register_user!()
    conn = log_in(conn, user)

    for {path, active, title} <- [
          {"/inbox", "inbox", "Inbox"},
          {"/inbox/subscriptions", "subscriptions", "Subscriptions"}
        ] do
      {:ok, view, _html} = live(conn, path)
      assert has_element?(view, ".ibx.ibx-workspace > .ibx-heading")
      assert has_element?(view, ".ibx-heading h1", title)
      assert has_element?(view, ".ibx-heading #view-nav-#{active}[aria-current=page]")
    end
  end

  @tag :selected_a
  test "package discovery uses search and obsolete package scope is not retained", %{conn: conn} do
    user = register_user!()
    {revision, [first, second]} = revision_notifications!(user, 2)

    {:ok, view, _html} =
      live(log_in(conn, user), ~p"/inbox?filter=all&package_id=#{first.package_id}")

    refute has_element?(view, "#inbox-package")
    refute has_element?(view, "[name=package_id]")
    group_counts(view, revision, 2, 2, 2)
    assert has_element?(view, "#notification-#{second.id}")
    view |> element("#filter-saved") |> render_click()
    refute Map.has_key?(assert_query(assert_patch(view), filter: "saved"), "package_id")
  end

  @tag :selected_a
  test "revision-linked propagation expands with its revision and per-row actions", %{conn: conn} do
    user = register_user!()
    {revision, [added]} = revision_notifications!(user, 1)
    change = change!()
    branch = change_branch!(change, "nixos-unstable", revision)

    propagated =
      notification!(user, %{
        type: :change_propagated,
        change_id: change.id,
        change_branch_id: branch.id,
        channel_id: revision.channel_id,
        channel_revision_id: revision.id
      })

    {:ok, view, _html} = live(log_in(conn, user), ~p"/inbox?filter=all")
    group_counts(view, revision, 2, 1, 2)
    assert has_element?(view, ".ibx-group-meta", "1 packages | 1 propagations")
    assert has_element?(view, "#revision-group-#{revision.id} #notification-#{added.id}")
    assert has_element?(view, "#revision-group-#{revision.id} #notification-#{propagated.id}")
    assert has_element?(view, "#notification-#{propagated.id} [aria-label='Save for later']")

    view
    |> element("#notification-#{propagated.id} [aria-label='Mark as read']")
    |> render_click()

    group_counts(view, revision, 2, 1, 1)
  end

  @tag :selected_a
  test "mixed channel groups show only three items by default", %{conn: conn} do
    user = register_user!()
    {revision, _notifications} = revision_notifications!(user, 3)
    change = change!()
    branch = change_branch!(change, "nixos-unstable", revision)

    notification!(user, %{
      type: :change_propagated,
      change_id: change.id,
      change_branch_id: branch.id,
      channel_id: revision.channel_id,
      channel_revision_id: revision.id
    })

    {:ok, view, _html} = live(log_in(conn, user), ~p"/inbox")
    assert length(group_rows(view, revision)) == 3
    assert has_element?(view, "[phx-click=show-more]", "Show 1 more")
    view |> element("[phx-click=show-more]") |> render_click()
    assert length(group_rows(view, revision)) == 4
  end

  test "unlinked propagation stays standalone rather than becoming a digest", %{conn: conn} do
    user = register_user!()

    notifications =
      for _ <- 1..2 do
        change = change!()
        branch = change_branch!(change, "nixos-unstable")

        notification!(user, %{
          type: :change_propagated,
          change_id: change.id,
          change_branch_id: branch.id,
          occurred_at: ~U[2026-11-06 12:00:00Z]
        })
      end

    {:ok, view, _html} = live(log_in(conn, user), ~p"/inbox?filter=all")

    refute has_element?(view, "[id^=propagation-group-]")
    refute has_element?(view, ".ibx-disclosure")

    for notification <- notifications do
      assert has_element?(
               view,
               ".ibx-day-entries > .row-list > #notification-#{notification.id}"
             )

      assert has_element?(view, "#notification-#{notification.id} [aria-label='Save for later']")
    end
  end

  @tag :selected_a
  test "revision-linked propagation previews are lazy and matching read preserves hidden siblings",
       %{
         conn: conn
       } do
    user = register_user!()
    revision = channel_revision!(channel!())

    notifications =
      for number <- 1..8 do
        change = change!(nil, %{title: "revision-matching-#{number}"})
        branch = change_branch!(change, "nixos-unstable", revision)

        notification!(user, %{
          type: :change_propagated,
          change_id: change.id,
          change_branch_id: branch.id,
          channel_id: revision.channel_id,
          channel_revision_id: revision.id
        })
      end

    hidden_change = change!(nil, %{title: "other-change"})
    hidden_branch = change_branch!(hidden_change, "nixos-unstable", revision)

    hidden =
      notification!(user, %{
        type: :change_propagated,
        change_id: hidden_change.id,
        change_branch_id: hidden_branch.id,
        channel_id: revision.channel_id,
        channel_revision_id: revision.id
      })

    {:ok, view, _html} = live(log_in(conn, user), ~p"/inbox?search=revision-matching")
    assert has_element?(view, "#revision-group-#{revision.id}[data-notification-count='8']")

    assert length(
             view
             |> render()
             |> Floki.parse_document!()
             |> Floki.find("#revision-group-#{revision.id} .notification-row")
           ) == 3

    refute has_element?(view, "#notification-#{hidden.id}")
    view |> element("#revision-group-#{revision.id} [phx-click=show-more]") |> render_click()

    for notification <- notifications do
      assert has_element?(view, "#notification-#{notification.id}")
    end

    saved = hd(notifications)
    view |> element("#notification-#{saved.id} [aria-label='Save for later']") |> render_click()
    assert has_element?(view, "#notification-#{saved.id} [aria-label='Remove from saved']")

    view
    |> element("#revision-group-#{revision.id} [phx-click=mark-group-read]")
    |> render_click()

    assert has_element?(view, "#inbox-empty")

    assert Enum.map(Notification.for_user!(%{unread_only: true}, actor: user), & &1.id) == [
             hidden.id
           ]
  end

  test "a revision larger than a flat page defaults to three expanded items", %{conn: conn} do
    user = register_user!()
    {revision, _notifications} = revision_notifications!(user, 30)
    {:ok, view, _html} = live(log_in(conn, user), ~p"/inbox")

    assert has_element?(view, "#revision-group-#{revision.id}")
    assert has_element?(view, "#revision-group-#{revision.id} [aria-expanded=true]")
    refute has_element?(view, "a[rel=next]")

    assert length(
             view
             |> render()
             |> Floki.parse_document!()
             |> Floki.find("#revision-group-#{revision.id} .notification-row")
           ) == 3

    assert has_element?(view, "#revision-group-#{revision.id} button", "Show 27 more")
    view |> element("#revision-group-#{revision.id} [aria-expanded]") |> render_click()
    assert has_element?(view, "#revision-group-#{revision.id} [aria-expanded=false]")
    assert group_rows(view, revision) == []
    view |> element("#revision-group-#{revision.id} [aria-expanded]") |> render_click()
    assert length(group_rows(view, revision)) == 3
    assert Enum.all?(Notification.for_user!(actor: user), &is_nil(&1.read_at))
  end

  test "group read affects hidden matching children but not another actor", %{conn: conn} do
    user = register_user!()
    other = register_user!()
    {revision, _notifications} = revision_notifications!(user, 30)

    foreign =
      notification!(other, %{
        type: :channel_revision_published,
        channel_revision_id: revision.id,
        channel_id: revision.channel_id
      })

    {:ok, view, _html} = live(log_in(conn, user), ~p"/inbox")

    view
    |> element("#revision-group-#{revision.id} [phx-click=mark-group-read]")
    |> render_click()

    assert Notification.for_user!(%{unread_only: true}, actor: user) == []

    assert Enum.any?(
             Notification.for_user!(%{unread_only: true}, actor: other),
             &(&1.id == foreign.id)
           )

    refute has_element?(view, "#revision-group-#{revision.id}")
  end

  test "search expands only matching children and reset preserves search and view", %{conn: conn} do
    user = register_user!()
    {revision, [matching, hidden]} = revision_notifications!(user, 2)
    matching = Ash.load!(matching, :package, actor: user)

    {:ok, view, _html} =
      live(
        log_in(conn, user),
        ~p"/inbox?filter=all&search=#{matching.package.attribute}&types=package_added"
      )

    assert has_element?(view, "#revision-group-#{revision.id} [aria-expanded=true]")
    assert has_element?(view, "#notification-#{matching.id}")
    refute has_element?(view, "#notification-#{hidden.id}")
    view |> element("#reset-filters") |> render_click()
    assert has_element?(view, "#filter-all.is-active")
    assert has_element?(view, "#notification-#{matching.id}")
    refute has_element?(view, "#notification-#{hidden.id}")
  end

  test "explicit filter controls remain available with no results", %{conn: conn} do
    user = register_user!()
    {:ok, view, _html} = live(log_in(conn, user), ~p"/inbox?types=none")

    assert has_element?(view, "#inbox-filters input[type=checkbox]")
    assert has_element?(view, "#inbox-filters select[name=channel_id]")
    refute has_element?(view, "#inbox-filters [name=package_id]")
    assert has_element?(view, "#reset-filters")
    assert has_element?(view, "#inbox-empty")
  end

  test "pagination counts revisions including linked propagation once", %{conn: conn} do
    user = register_user!()
    revisions = for _ <- 1..26, do: elem(revision_notifications!(user, 2), 0)
    revision = hd(revisions)
    change = change!()

    propagation =
      notification!(user, %{
        type: :change_propagated,
        change_id: change.id,
        channel_revision_id: revision.id,
        channel_id: revision.channel_id
      })

    {:ok, first, _html} = live(log_in(conn, user), ~p"/inbox?filter=all")

    first_ids =
      first
      |> render()
      |> Floki.parse_document!()
      |> Floki.find("[id^=revision-group-]")
      |> Floki.attribute("id")

    assert length(first_ids) == 25
    assert has_element?(first, "#revision-group-#{revision.id} #notification-#{propagation.id}")

    {:ok, second, _html} = live(log_in(conn, user), ~p"/inbox?filter=all&page=2")

    second_ids =
      second
      |> render()
      |> Floki.parse_document!()
      |> Floki.find("[id^=revision-group-]")
      |> Floki.attribute("id")

    assert length(second_ids) == 1
    assert MapSet.disjoint?(MapSet.new(first_ids), MapSet.new(second_ids))
    assert length(Enum.uniq(first_ids ++ second_ids)) == 26
  end

  test "search-scoped group read preserves a hidden sibling", %{conn: conn} do
    user = register_user!()
    {revision, [matching, hidden]} = revision_notifications!(user, 2)
    matching = Ash.load!(matching, :package, actor: user)
    {:ok, view, _html} = live(log_in(conn, user), ~p"/inbox?search=#{matching.package.attribute}")
    group_counts(view, revision, 1, 1, 1)

    assert has_element?(
             view,
             "#revision-group-#{revision.id} [phx-click=mark-group-read]",
             "Mark matching read"
           )

    view
    |> element("#revision-group-#{revision.id} [phx-click=mark-group-read]")
    |> render_click()

    assert Enum.map(Notification.for_user!(%{unread_only: true}, actor: user), & &1.id) == [
             hidden.id
           ]

    assert has_element?(view, "#inbox-empty")
  end

  test "all-matching read crosses entry pages", %{conn: conn} do
    user = register_user!()
    for _ <- 1..26, do: revision_notifications!(user, 2)
    {:ok, view, _html} = live(log_in(conn, user), ~p"/inbox")

    view |> element("#mark-all-read") |> render_click()

    assert Notification.for_user!(%{unread_only: true}, actor: user) == []
    assert has_element?(view, "#inbox-empty")
  end

  test "mixed groups count notifications separately from distinct packages", %{conn: conn} do
    user = register_user!()
    {revision, [added]} = revision_notifications!(user, 1)

    removed =
      notification!(user, %{
        type: :package_removed,
        package_id: added.package_id,
        channel_id: revision.channel_id,
        channel_revision_id: revision.id
      })

    published =
      notification!(user, %{
        type: :channel_revision_published,
        channel_id: revision.channel_id,
        channel_revision_id: revision.id
      })

    {:ok, view, _html} = live(log_in(conn, user), ~p"/inbox")
    group_counts(view, revision, 3, 1, 3)
    channel = Ash.get!(Tracker.Nixpkgs.Channel, revision.channel_id)

    assert has_element?(
             view,
             "#revision-group-#{revision.id} a[href^='/channels/#{channel.name}/revisions/#{revision.revision}'][aria-label='Open full revision']"
           )

    assert Enum.sort(group_rows(view, revision)) ==
             Enum.sort(Enum.map([added, removed, published], &"notification-#{&1.id}"))

    assert has_element?(view, "#notification-#{published.id} [aria-label='Mark as read']")
    assert has_element?(view, "#notification-#{published.id} [aria-label='Save for later']")
  end

  test "a revision-only group is visible and individually actionable", %{conn: conn} do
    user = register_user!()
    channel = channel!()
    revision = channel_revision!(channel)

    published =
      notification!(user, %{
        type: :channel_revision_published,
        channel_id: channel.id,
        channel_revision_id: revision.id
      })

    {:ok, view, _html} = live(log_in(conn, user), ~p"/inbox?filter=all")
    group_counts(view, revision, 1, 0, 1)
    assert group_rows(view, revision) == ["notification-#{published.id}"]

    view
    |> element("#notification-#{published.id} [aria-label='Save for later']")
    |> render_click()

    view |> element("#notification-#{published.id} [aria-label='Mark as read']") |> render_click()

    group_counts(view, revision, 1, 0, 0)
    assert has_element?(view, "#revision-group-#{revision.id} [aria-expanded=true]")

    assert %Notification{saved: true, read_at: read_at} =
             Ash.get!(Notification, published.id, actor: user)

    refute is_nil(read_at)
  end

  test "read and Saved views project only matching members without independent group state", %{
    conn: conn
  } do
    user = register_user!()
    {revision, [saved_read, saved_unread, unsaved]} = revision_notifications!(user, 3)

    saved_read =
      saved_read |> Notification.save!(actor: user) |> Notification.mark_read!(actor: user)

    Notification.save!(saved_unread, actor: user)
    conn = log_in(conn, user)

    {:ok, unread, _html} = live(conn, ~p"/inbox")
    group_counts(unread, revision, 2, 2, 2)
    {:ok, all, _html} = live(conn, ~p"/inbox?filter=all")
    group_counts(all, revision, 3, 3, 2)
    {:ok, saved, _html} = live(conn, ~p"/inbox?filter=saved")
    group_counts(saved, revision, 2, 2, 1)

    assert has_element?(saved, "#notification-#{saved_read.id}:not(.is-unread)")
    assert has_element?(saved, "#notification-#{saved_unread.id}.is-unread")
    refute has_element?(saved, "#notification-#{unsaved.id}")

    saved
    |> element("#revision-group-#{revision.id} [phx-click=mark-group-read]")
    |> render_click()

    group_counts(saved, revision, 2, 2, 0)
    assert has_element?(saved, "#notification-#{saved_unread.id}")
    assert Ash.get!(Notification, saved_read.id, actor: user).read_at == saved_read.read_at

    assert %Notification{saved: false, read_at: nil} =
             Ash.get!(Notification, unsaved.id, actor: user)
  end

  test "show more and fewer are inline, bounded, and preserve read state", %{conn: conn} do
    user = register_user!()
    {revision, _notifications} = revision_notifications!(user, 8)
    {:ok, view, _html} = live(log_in(conn, user), ~p"/inbox")

    assert has_element?(
             view,
             "#revision-group-#{revision.id} [phx-click=show-more]",
             "Show 5 more"
           )

    assert has_element?(view, "#revision-group-#{revision.id} .ibx-group-meta", "8 packages")
    refute has_element?(view, ".ibx-group-meta", "unread")
    refute has_element?(view, ".ibx-group-meta", "matching notifications")
    assert length(group_rows(view, revision)) == 3
    view |> element("#revision-group-#{revision.id} [phx-click=show-more]") |> render_click()
    assert length(group_rows(view, revision)) > 3
    assert length(group_rows(view, revision)) <= 8
    assert has_element?(view, "#revision-group-#{revision.id} [phx-click=show-fewer]")
    view |> element("#revision-group-#{revision.id} [phx-click=show-fewer]") |> render_click()
    assert length(group_rows(view, revision)) == 3
    assert has_element?(view, "#revision-group-#{revision.id} [aria-expanded=true]")
    assert Enum.all?(Notification.for_user!(actor: user), &is_nil(&1.read_at))
  end

  test "clearing search restores prior expanded and collapsed groups", %{conn: conn} do
    user = register_user!()
    {expanded, [expanded_notification]} = revision_notifications!(user, 1)
    {collapsed, [collapsed_notification]} = revision_notifications!(user, 1)
    channel = Ash.get!(Tracker.Nixpkgs.Channel, collapsed.channel_id)
    {:ok, view, _html} = live(log_in(conn, user), ~p"/inbox?filter=all")

    view |> element("#revision-group-#{collapsed.id} [phx-click=toggle-group]") |> render_click()
    view |> element("#page-search") |> render_change(%{"search" => channel.name})
    search_path = assert_patch(view)
    assert_query(search_path, filter: "all", search: channel.name)
    assert has_element?(view, "#revision-group-#{collapsed.id} [aria-expanded=true]")
    assert has_element?(view, "#notification-#{collapsed_notification.id}")
    refute has_element?(view, "#revision-group-#{expanded.id}")

    view |> element("#page-search") |> render_change(%{"search" => ""})
    clear_path = assert_patch(view)
    refute Map.has_key?(assert_query(clear_path, filter: "all"), "search")
    assert has_element?(view, "#revision-group-#{expanded.id} [aria-expanded=true]")
    assert has_element?(view, "#notification-#{expanded_notification.id}")
    assert has_element?(view, "#revision-group-#{collapsed.id} [aria-expanded=false]")
    refute has_element?(view, "#notification-#{collapsed_notification.id}")
  end

  test "all types are selected by default and deselecting the final type means none", %{
    conn: conn
  } do
    user = register_user!()
    {revision, _notifications} = revision_notifications!(user, 1)
    {:ok, view, _html} = live(log_in(conn, user), ~p"/inbox?types=package_added")
    assert has_element?(view, "#filter-type-package_added[checked]")
    refute has_element?(view, "#filter-type-package_removed[checked]")

    view |> element("#filter-type-package_added") |> render_click()
    path = assert_patch(view)
    assert_query(path, types: "none")
    assert has_element?(view, "#inbox-empty")
    refute has_element?(view, "#inbox-filters input[type=checkbox][checked]")
    assert has_element?(view, "#mark-all-read[disabled]")

    {:ok, reloaded, _html} = live(log_in(conn, user), path)
    assert has_element?(reloaded, "#inbox-empty")
    reloaded |> element("#reset-filters") |> render_click()
    reset_path = assert_patch(reloaded)
    refute Map.has_key?(URI.decode_query(URI.parse(reset_path).query || ""), "types")
    assert has_element?(reloaded, "#revision-group-#{revision.id}")

    checked =
      reloaded
      |> render()
      |> Floki.parse_document!()
      |> Floki.find("#inbox-filters input[type=checkbox][checked]")

    assert length(checked) == 7
  end

  test "scope controls and reset preserve view search and revision across a reload", %{conn: conn} do
    user = register_user!()
    {revision, [matching, sibling]} = revision_notifications!(user, 2)
    Notification.save!(matching, actor: user)
    Notification.save!(sibling, actor: user)
    channel = Ash.get!(Tracker.Nixpkgs.Channel, revision.channel_id)
    conn = log_in(conn, user)

    params = %{
      filter: "saved",
      search: channel.name,
      types: "package_added",
      channel_revision_id: revision.id,
      channel_id: channel.id
    }

    {:ok, view, _html} = live(conn, ~p"/inbox?#{params}")
    group_counts(view, revision, 2, 2, 2)

    assert has_element?(
             view,
             "#inbox-filters select[name=channel_id] option[value='#{channel.id}'][selected]"
           )

    refute has_element?(view, "#inbox-filters [name=package_id]")
    assert has_element?(view, "#notification-#{sibling.id}")

    view |> element("#reset-filters") |> render_click()
    path = assert_patch(view)

    query =
      assert_query(path, filter: "saved", search: channel.name, channel_revision_id: revision.id)

    for key <- ["types", "channel_id", "package_id", "page"], do: refute(Map.has_key?(query, key))
    group_counts(view, revision, 2, 2, 2)
    assert has_element?(view, "#notification-#{matching.id}")
    assert has_element?(view, "#notification-#{sibling.id}")

    {:ok, reloaded, _html} = live(conn, path)
    group_counts(reloaded, revision, 2, 2, 2)
    assert has_element?(reloaded, "#filter-saved.is-active")
    assert has_element?(reloaded, "#page-search-input[value='#{channel.name}']")
  end

  test "consecutive scoped row reads and reset keep the URL and ledger consistent", %{conn: conn} do
    user = register_user!()
    {revision, [first, second, hidden]} = revision_notifications!(user, 3)
    channel = Ash.get!(Tracker.Nixpkgs.Channel, revision.channel_id)
    conn = log_in(conn, user)
    {:ok, view, _html} = live(conn, ~p"/inbox?search=#{channel.name}")

    for notification <- [first, second] do
      view
      |> form("#inbox-filters form", %{
        "channel_id" => to_string(channel.id)
      })
      |> render_change()

      path = assert_patch(view)

      assert_query(path,
        search: channel.name,
        channel_id: channel.id
      )

      view
      |> element("#notification-#{notification.id} [aria-label='Mark as read']")
      |> render_click()

      refute has_element?(view, "#notification-#{notification.id}")

      assert %Notification{read_at: read_at} =
               Ash.get!(Notification, notification.id, actor: user)

      refute is_nil(read_at)
      view |> element("#reset-filters") |> render_click()
      reset_path = assert_patch(view)
      assert_query(reset_path, search: channel.name)
      refute Map.has_key?(URI.decode_query(URI.parse(reset_path).query || ""), "package_id")
    end

    assert has_element?(view, "#notification-#{hidden.id}")
    {:ok, reloaded, _html} = live(conn, ~p"/inbox?search=#{channel.name}")
    group_counts(reloaded, revision, 1, 1, 1)
    assert has_element?(reloaded, "#notification-#{hidden.id}")

    assert Enum.map(Notification.for_user!(%{unread_only: true}, actor: user), & &1.id) == [
             hidden.id
           ]
  end

  test "reading the final group on a page clamps to the surviving entry page", %{conn: conn} do
    user = register_user!()
    revisions = for _ <- 1..26, do: elem(revision_notifications!(user, 1), 0)
    conn = log_in(conn, user)
    {:ok, view, _html} = live(conn, ~p"/inbox?types=package_added&page=2")

    [last_id] =
      view
      |> render()
      |> Floki.parse_document!()
      |> Floki.find("[id^=revision-group-]")
      |> Floki.attribute("id")

    last = Enum.find(revisions, &("revision-group-#{&1.id}" == last_id))

    view |> element("##{last_id} [phx-click=mark-group-read]") |> render_click()
    path = assert_patch(view)
    query = assert_query(path, types: "package_added")
    assert query["page"] in [nil, "1"]
    refute has_element?(view, "##{last_id}")
    refute has_element?(view, "a[rel=next]")
    assert length(Notification.for_user!(%{unread_only: true}, actor: user)) == 25

    assert Enum.all?(
             Notification.for_user!(%{channel_revision_id: last.id}, actor: user),
             & &1.read_at
           )

    {:ok, reloaded, _html} = live(conn, path)
    refute has_element?(reloaded, "##{last_id}")

    assert length(
             reloaded
             |> render()
             |> Floki.parse_document!()
             |> Floki.find("[id^=revision-group-]")
           ) == 25
  end

  test "live member arrivals update counts without collapsing an expanded group", %{conn: conn} do
    user = register_user!()
    {revision, [existing]} = revision_notifications!(user, 1)
    {:ok, view, _html} = live(log_in(conn, user), ~p"/inbox")

    added =
      notification!(user, %{
        type: :package_added,
        package_id: package!().id,
        channel_id: revision.channel_id,
        channel_revision_id: revision.id
      })

    group_counts(view, revision, 2, 2, 2)
    assert has_element?(view, "#revision-group-#{revision.id} [aria-expanded=true]")
    assert has_element?(view, "#notification-#{existing.id}")
    assert has_element?(view, "#notification-#{added.id}")
  end

  test "row and group reads preserve another group's expansion", %{conn: conn} do
    user = register_user!()
    {revision, [first, _second]} = revision_notifications!(user, 2)
    {unaffected, [survivor]} = revision_notifications!(user, 1)
    {:ok, view, _html} = live(log_in(conn, user), ~p"/inbox")

    view |> element("#notification-#{first.id} [aria-label='Mark as read']") |> render_click()
    refute has_element?(view, "#notification-#{first.id}")
    group_counts(view, revision, 1, 1, 1)
    assert has_element?(view, "#revision-group-#{revision.id} [aria-expanded=true]")
    assert has_element?(view, "#revision-group-#{unaffected.id} [aria-expanded=true]")

    view
    |> element("#revision-group-#{revision.id} [phx-click=mark-group-read]")
    |> render_click()

    refute has_element?(view, "#revision-group-#{revision.id}")
    assert has_element?(view, "#revision-group-#{unaffected.id} [aria-expanded=true]")
    assert has_element?(view, "#notification-#{survivor.id}")
    assert %Notification{read_at: nil} = Ash.get!(Notification, survivor.id, actor: user)
  end

  test "case-insensitive search scopes counts, show-more and matching read", %{conn: conn} do
    user = register_user!()
    channel = channel!()
    revision = channel_revision!(channel)
    needle = "matching-preview-#{System.unique_integer([:positive])}"

    matching =
      for number <- 1..8 do
        package = package!("#{needle}-#{number}")

        notification!(user, %{
          type: :package_added,
          package_id: package.id,
          channel_id: channel.id,
          channel_revision_id: revision.id
        })
      end

    hidden =
      notification!(user, %{
        type: :package_added,
        package_id: package!().id,
        channel_id: channel.id,
        channel_revision_id: revision.id
      })

    {:ok, view, _html} = live(log_in(conn, user), ~p"/inbox?search=#{String.upcase(needle)}")
    group_counts(view, revision, 8, 8, 8)
    assert length(group_rows(view, revision)) == 3
    view |> element("#revision-group-#{revision.id} [phx-click=show-more]") |> render_click()
    visible_ids = group_rows(view, revision)
    assert length(visible_ids) > 3
    matching_ids = Enum.map(matching, &"notification-#{&1.id}")
    assert Enum.all?(visible_ids, &(&1 in matching_ids))
    refute has_element?(view, "#notification-#{hidden.id}")

    view
    |> element("#revision-group-#{revision.id} [phx-click=mark-group-read]")
    |> render_click()

    assert has_element?(view, "#inbox-empty")

    assert Enum.map(Notification.for_user!(%{unread_only: true}, actor: user), & &1.id) == [
             hidden.id
           ]
  end

  test "show more fetches only the requested member limit for each expanded group", %{conn: conn} do
    user = register_user!()
    {expanded, _notifications} = revision_notifications!(user, 8)
    {preview, _notifications} = revision_notifications!(user, 8)
    {:ok, view, _html} = live(log_in(conn, user), ~p"/inbox")

    for revision <- [expanded, preview] do
      assert length(group_rows(view, revision)) == 3
    end

    owner = self()
    handler = {__MODULE__, make_ref()}
    event = Tracker.Repo.config()[:telemetry_prefix] ++ [:query]

    :ok =
      :telemetry.attach(
        handler,
        event,
        fn _event, _measurements, metadata, {owner, user_id} ->
          case metadata.result do
            {:ok, %{columns: columns, rows: rows}} when is_list(columns) and is_list(rows) ->
              if "__order__" in columns and
                   Enum.all?(["user_id", "channel_revision_id", "package_id"], &(&1 in columns)) do
                user_index = Enum.find_index(columns, &(&1 == "user_id"))
                revision_index = Enum.find_index(columns, &(&1 == "channel_revision_id"))
                package_index = Enum.find_index(columns, &(&1 == "package_id"))

                for row <- rows,
                    Enum.at(row, user_index) == user_id,
                    not is_nil(Enum.at(row, package_index)) do
                  send(owner, {:inbox_member_fetch, Enum.at(row, revision_index)})
                end
              end

            _result ->
              :ok
          end
        end,
        {owner, Ecto.UUID.dump!(user.id)}
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    view |> element("#revision-group-#{expanded.id} [phx-click=show-more]") |> render_click()

    assert length(group_rows(view, expanded)) == 8
    assert length(group_rows(view, preview)) == 3
    fetched = collect_member_fetches([])
    assert Enum.frequencies(fetched) == %{expanded.id => 8, preview.id => 3}
  end

  test "collapsing search results does not overwrite ordinary expansion state", %{conn: conn} do
    user = register_user!()
    {expanded, [expanded_notification]} = revision_notifications!(user, 1)
    {collapsed, [collapsed_notification]} = revision_notifications!(user, 1)
    {:ok, view, _html} = live(log_in(conn, user), ~p"/inbox")
    view |> element("#revision-group-#{collapsed.id} [phx-click=toggle-group]") |> render_click()

    view |> element("#page-search") |> render_change(%{"search" => "pkg-"})
    assert_patch(view)
    assert has_element?(view, "#revision-group-#{expanded.id} [aria-expanded=true]")
    assert has_element?(view, "#revision-group-#{collapsed.id} [aria-expanded=true]")
    view |> element("#revision-group-#{expanded.id} [phx-click=toggle-group]") |> render_click()
    assert has_element?(view, "#revision-group-#{expanded.id} [aria-expanded=false]")
    refute has_element?(view, "#notification-#{expanded_notification.id}")

    view |> element("#page-search") |> render_change(%{"search" => ""})
    assert_patch(view)
    assert has_element?(view, "#revision-group-#{expanded.id} [aria-expanded=true]")
    assert has_element?(view, "#notification-#{expanded_notification.id}")
    assert has_element?(view, "#revision-group-#{collapsed.id} [aria-expanded=false]")
    refute has_element?(view, "#notification-#{collapsed_notification.id}")
  end

  defp collect_member_fetches(revisions) do
    receive do
      {:inbox_member_fetch, revision_id} -> collect_member_fetches([revision_id | revisions])
    after
      0 -> revisions
    end
  end
end

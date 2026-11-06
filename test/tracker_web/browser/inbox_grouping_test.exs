defmodule TrackerWeb.Browser.InboxGroupingTest do
  use TrackerWeb.PlaywrightCase

  alias Tracker.Notifications.Notification

  setup do
    path = Path.join(System.tmp_dir!(), "dev-login-#{System.unique_integer([:positive])}.json")
    Application.put_env(:tracker, :dev_login_file, path)
    on_exit(fn -> File.rm(path) end)

    user = register_user!()
    channel = channel!()
    revision = channel_revision!(channel)
    package = package!("inbox-browser-#{System.unique_integer([:positive])}")

    notification =
      notification!(user, %{
        type: :package_added,
        package_id: package.id,
        channel_id: channel.id,
        channel_revision_id: revision.id
      })

    %{user: user, channel: channel, revision: revision, notification: notification}
  end

  defp read(conn, expression) do
    parent = self()
    evaluate(conn, expression, &send(parent, {:read, &1}))

    receive do
      {:read, value} -> value
    after
      0 -> flunk("evaluate/3 returned no value for #{expression}")
    end
  end

  defp inbox(conn, user, path \\ "/inbox") do
    conn
    |> visit("/dev/login/#{Tracker.DevLogin.issue!(user.github_username)}")
    |> visit(path)
    |> assert_has("[data-phx-main].phx-connected")
  end

  test "disclosure supports Enter and Space without navigating or marking read", %{
    conn: conn,
    user: user,
    revision: revision,
    notification: notification
  } do
    conn = inbox(conn, user)
    disclosure = "#revision-group-#{revision.id} [phx-click=toggle-group]"
    assert_has(conn, "#{disclosure}[aria-expanded=false]")
    press(conn, disclosure, "Enter")
    assert_has(conn, "#{disclosure}[aria-expanded=true]")
    assert_has(conn, "#notification-#{notification.id}")
    assert read(conn, "document.activeElement.matches('[phx-click=toggle-group]')")
    assert_path(conn, "/inbox")
    assert %Notification{read_at: nil} = Ash.get!(Notification, notification.id, actor: user)

    press(conn, disclosure, "Space")
    assert_has(conn, "#{disclosure}[aria-expanded=false]")
    refute_has(conn, "#notification-#{notification.id}")
    assert read(conn, "document.activeElement.matches('[phx-click=toggle-group]')")
    assert %Notification{read_at: nil} = Ash.get!(Notification, notification.id, actor: user)
  end

  test "filter reset and browser history round-trip the selected scope", %{
    conn: conn,
    user: user,
    channel: channel,
    revision: revision
  } do
    conn =
      inbox(
        conn,
        user,
        "/inbox?filter=all&channel_id=#{channel.id}"
      )

    assert_restored_scope(conn, channel.id)
    click(conn, "#reset-filters")
    assert_scope_value(conn, "")
    assert_has(conn, "#filter-all.is-active")
    assert read(conn, "new URL(location.href).searchParams.has('channel_id')") == false
    refute_has(conn, "[name=package_id]")

    evaluate(conn, "history.back()")
    assert_restored_scope(conn, channel.id)
    assert_has(conn, "#revision-group-#{revision.id}")

    evaluate(conn, "history.forward()")
    assert_scope_value(conn, "")
    assert read(conn, "new URL(location.href).searchParams.has('channel_id')") == false
    assert_has(conn, "#filter-all.is-active")

    path = read(conn, "location.pathname + location.search")
    conn = visit(conn, path)
    assert_has(conn, "#filter-all.is-active")
    assert_has(conn, "#revision-group-#{revision.id}")
    assert_scope_value(conn, "")
  end

  defp assert_restored_scope(conn, channel_id) do
    assert_path(conn, "/inbox")

    PhoenixTest.Playwright.retry(
      fn ->
        assert read(
                 conn,
                 ~s|["filter","channel_id"].map(key => new URL(location.href).searchParams.get(key))|
               ) == ["all", to_string(channel_id)]
      end,
      timeout()
    )

    assert_scope_value(conn, channel_id)
  end

  defp assert_scope_value(conn, channel_id) do
    PhoenixTest.Playwright.retry(
      fn ->
        assert read(
                 conn,
                 ~s|document.querySelector("#inbox-channel")?.value|
               ) == to_string(channel_id)
      end,
      timeout()
    )
  end

  @tag browser_context_opts: [viewport: %{width: 390, height: 844}]
  test "mobile filters disclose accessibly and expanded groups do not overflow", %{
    conn: conn,
    user: user,
    revision: revision,
    notification: notification
  } do
    conn = inbox(conn, user)
    assert read(conn, "window.innerWidth") == 390
    assert_has(conn, "#inbox-filters:not([open])")
    press(conn, "#inbox-filters > summary", "Enter")
    assert_has(conn, "#inbox-filters[open]")
    press(conn, "#inbox-filters > summary", "Space")
    assert_has(conn, "#inbox-filters:not([open])")
    press(conn, "#inbox-filters > summary", "Enter")
    assert_has(conn, "#inbox-filters[open]")
    assert_has(conn, "#inbox-filters input[type=checkbox]")
    assert_has(conn, "#inbox-filters select[name=channel_id]")
    refute_has(conn, "[name=package_id]")
    click(conn, "#revision-group-#{revision.id} [phx-click=toggle-group]")
    assert_has(conn, "#notification-#{notification.id}")
    assert read(conn, "document.documentElement.scrollWidth <= window.innerWidth")
    assert read(conn, "document.body.scrollWidth <= window.innerWidth")
    assert %Notification{read_at: nil} = Ash.get!(Notification, notification.id, actor: user)
  end

  @tag :selected_a
  @tag browser_context_opts: [viewport: %{width: 1440, height: 1060}]
  test "desktop Inbox and Subscriptions use the same wide shell and divider-led rows", %{
    conn: conn,
    user: user,
    revision: revision,
    notification: notification
  } do
    Tracker.Notifications.PackageSubscription.subscribe!(notification.package_id, nil,
      actor: user
    )

    for _ <- 1..2,
        do: notification!(user, %{type: :package_change_opened, change_id: change!().id})

    change = change!(nil, %{title: "linked-browser-propagation"})
    branch = change_branch!(change, "nixos-unstable", revision)

    propagated =
      notification!(user, %{
        type: :change_propagated,
        change_id: change.id,
        change_branch_id: branch.id,
        channel_id: revision.channel_id,
        channel_revision_id: revision.id
      })

    conn = inbox(conn, user)
    assert_has(conn, ".ibx-workspace > .ibx-heading #view-nav-inbox[aria-current=page]")

    assert read(
             conn,
             "getComputedStyle(document.querySelector('.ibx-layout')).gridTemplateColumns.split(' ').length"
           ) == 2

    assert read(conn, "document.querySelector('.ibx-sidebar').getBoundingClientRect().width") >=
             220

    width = read(conn, "document.querySelector('.ibx-workspace').getBoundingClientRect().width")
    assert width > 1000

    assert read(
             conn,
             "Array.from(document.querySelectorAll('.ibx-day-entries > .row-list')).every(el => getComputedStyle(el).borderTopWidth === '0px' && getComputedStyle(el).borderRadius === '0px')"
           )

    assert read(conn, "document.querySelectorAll('.ibx-day-entries > .row-list').length") == 2
    click(conn, "#revision-group-#{revision.id} [phx-click=toggle-group]")
    assert_has(conn, "#notification-#{notification.id}")
    assert_has(conn, "#revision-group-#{revision.id} #notification-#{propagated.id}")
    click(conn, "#notification-#{propagated.id} [aria-label='Save for later']")
    assert_has(conn, "#notification-#{propagated.id} [aria-label='Remove from saved']")
    conn = fill_in(conn, "Search notifications…", with: "linked-browser-propagation")
    assert_has(conn, "#revision-group-#{revision.id}[data-notification-count='1']")
    assert_has(conn, "#notification-#{propagated.id}")
    refute_has(conn, "#notification-#{notification.id}")
    click(conn, "#notification-#{propagated.id} [aria-label='Mark as read']")
    assert_has(conn, "#inbox-empty")
    click(conn, "#view-nav-subscriptions")
    assert_has(conn, ".ibx-workspace > .ibx-heading #view-nav-subscriptions[aria-current=page]")

    assert read(conn, "document.querySelector('.ibx-workspace').getBoundingClientRect().width") ==
             width

    assert_has(conn, "#package-subscriptions")
    assert read(conn, "document.documentElement.scrollWidth <= window.innerWidth")
  end

  @tag :selected_a
  @tag browser_context_opts: [viewport: %{width: 390, height: 844}]
  test "mobile propagation digests expand, search, save and read without overflow", %{
    conn: conn,
    user: user
  } do
    matching_change = change!(nil, %{title: "digest-browser-matching"})
    hidden_change = change!(nil, %{title: "digest-browser-hidden"})

    [matching, hidden] =
      for change <- [matching_change, hidden_change] do
        branch = change_branch!(change, "nixos-unstable")

        notification!(user, %{
          type: :change_propagated,
          change_id: change.id,
          change_branch_id: branch.id,
          occurred_at: ~U[2026-11-06 12:00:00Z]
        })
      end

    conn = inbox(conn, user, "/inbox?filter=all")
    assert_has(conn, ".ibx-propagation-group[data-notification-count='2']")
    press(conn, ".ibx-propagation-group [phx-click=toggle-group]", "Enter")
    assert_has(conn, ".ibx-propagation-group #notification-#{matching.id}")
    assert_has(conn, ".ibx-propagation-group #notification-#{hidden.id}")
    conn = fill_in(conn, "Search notifications…", with: "digest-browser-matching")
    assert_has(conn, ".ibx-propagation-group[data-notification-count='1']")
    assert_has(conn, "#notification-#{matching.id}")
    refute_has(conn, "#notification-#{hidden.id}")
    click(conn, "#notification-#{matching.id} [aria-label='Save for later']")
    assert_has(conn, "#notification-#{matching.id} [aria-label='Remove from saved']")
    click(conn, "#notification-#{matching.id} [aria-label='Mark as read']")
    assert_has(conn, "#notification-#{matching.id} [aria-label='Mark as unread']")
    assert read(conn, "document.documentElement.scrollWidth <= window.innerWidth")
    assert read(conn, "document.body.scrollWidth <= window.innerWidth")
    width = read(conn, "document.querySelector('.ibx-workspace').getBoundingClientRect().width")
    assert width >= 342 and width <= 390
    click(conn, "#view-nav-subscriptions")
    assert_has(conn, ".ibx-workspace > .ibx-heading #view-nav-subscriptions[aria-current=page]")
    assert read(conn, "document.documentElement.scrollWidth <= window.innerWidth")

    assert read(conn, "document.querySelector('.ibx-workspace').getBoundingClientRect().width") ==
             width
  end

  test "the actual Clear search control restores ordinary group expansion", %{
    conn: conn,
    user: user,
    revision: revision,
    notification: notification
  } do
    channel = channel!()
    other_revision = channel_revision!(channel)

    notification!(user, %{
      type: :package_added,
      package_id: package!().id,
      channel_id: channel.id,
      channel_revision_id: other_revision.id
    })

    conn = inbox(conn, user)
    click(conn, "#revision-group-#{revision.id} [phx-click=toggle-group]")
    assert_has(conn, "#notification-#{notification.id}")
    conn = fill_in(conn, "Search notifications…", with: "inbox-browser")
    assert_has(conn, "a.app-search__clear")
    refute_has(conn, "#revision-group-#{other_revision.id}")

    click(conn, "a.app-search__clear")

    assert_has(conn, "#revision-group-#{revision.id} [aria-expanded=true]")
    assert_has(conn, "#notification-#{notification.id}")
    assert_has(conn, "#revision-group-#{other_revision.id} [aria-expanded=false]")
    assert read(conn, "new URL(location.href).searchParams.has('search')") == false
  end

  test "m keeps focus outside a disappearing final unread group", context do
    assert_final_group_cursor(context, :unread, "m")
  end

  test "s keeps focus outside a disappearing final saved group", context do
    assert_final_group_cursor(context, :saved, "s")
  end

  defp assert_final_group_cursor(context, filter, key) do
    preceding =
      notification!(context.user, %{
        occurred_at: DateTime.add(DateTime.utc_now(:second), 60, :second)
      })

    if filter == :saved do
      Notification.save!(preceding, actor: context.user)
      Notification.save!(context.notification, actor: context.user)
    end

    conn = inbox(context.conn, context.user, "/inbox?filter=#{filter}")
    click(conn, "#revision-group-#{context.revision.id} [phx-click=toggle-group]")
    press(conn, "#notification-#{context.notification.id} > .row-line", key)
    refute_has(conn, "#revision-group-#{context.revision.id}")
    assert_has(conn, "#notification-#{preceding.id}")
    assert_focus(conn, preceding.id)
  end

  defp assert_focus(conn, notification_id, attempts \\ 40) do
    expected = "notification-#{notification_id}"
    actual = read(conn, "document.activeElement.closest('ul.row-list > li')?.id ?? ''")

    cond do
      actual == expected ->
        :ok

      attempts == 0 ->
        assert actual == expected

      true ->
        Process.sleep(50)
        assert_focus(conn, notification_id, attempts - 1)
    end
  end
end

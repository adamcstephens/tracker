defmodule TrackerWeb.DashboardLive.IndexTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tracker.Fixtures

  alias AshAuthentication.Plug.Helpers
  alias Tracker.Notifications.ChangeSubscription
  alias Tracker.Notifications.Notification

  test "root is a public dashboard in disconnected and connected requests", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)
    assert html =~ "id=\"dashboard\""
    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, "#dashboard", "Welcome")
    refute has_element?(view, "#dashboard-inbox")
    refute has_element?(view, "#dashboard-followed-changes")
  end

  test "packages remains the searchable package listing", %{conn: conn} do
    package!("dashboard-search-target")
    {:ok, view, _} = live(conn, ~p"/packages?channel=all&search=dashboard-search-target")
    assert has_element?(view, "a[href*='/packages/dashboard-search-target']")
    refute has_element?(view, "#dashboard")
  end

  test "concrete revision previews prefer changed, added and removed over alphabetical truncation",
       %{conn: conn} do
    {channel, previous, current} = comparison_fixture!()
    {:ok, view, _} = live(conn, "/?channel=#{channel.name}")
    assert has_element?(view, "#dashboard-revision-summary", String.slice(current.revision, 0, 7))

    for {section, names} <- [
          {"#dashboard-package-changes", ["alpha-changed", "omega-added", "zulu-removed"]},
          {"#dashboard-option-changes", ["alpha.changed", "omega.added", "zulu.removed"]}
        ] do
      for name <- names, do: assert(has_element?(view, section, name))
      refute has_element?(view, section, "beta")

      assert has_element?(
               view,
               "#{section} a[href*='/channels/#{channel.name}/revisions/#{current.revision}']"
             )
    end

    for {parameter, fragment} <- [{"change", "packages"}, {"option_change", "options"}],
        {kind, count} <- [{"changed", "2"}, {"added", "1"}, {"removed", "1"}] do
      links =
        nodes(view, "#dashboard-revision-summary a[href]")
        |> Enum.filter(fn link ->
          [href] = Floki.attribute(link, "href")
          query = URI.parse(href).query || ""
          URI.decode_query(query)[parameter] == kind
        end)

      assert length(links) == 1
      [link] = links
      assert Floki.text(link) =~ count
      [href] = Floki.attribute(link, "href")
      uri = URI.parse(href)
      assert uri.fragment == fragment
      assert uri.path == "/channels/#{channel.name}/revisions/#{current.revision}"
      query = URI.decode_query(uri.query)
      assert query["channel"] == channel.name
      assert query["rev"] == current.revision
      assert query[parameter] == kind
    end

    assert has_element?(view, "#dashboard-package-changes", "1")
    assert has_element?(view, "#dashboard-package-changes", "2")
    assert has_element?(view, "#dashboard-option-changes", "boolean")
    assert has_element?(view, "#dashboard-option-changes", "string")
    refute render(view) =~ "#{previous.revision}/#{previous.revision}"
  end

  test "pinned revision remains pinned when a newer release exists", %{conn: conn} do
    {channel, previous, current} = comparison_fixture!()

    newer =
      channel_revision!(channel, %{
        revision: "newest-dashboard-revision",
        released_at: ~U[2026-09-03 00:00:00Z],
        previous_channel_revision_id: current.id
      })

    apply_package_revision!(newer, [{package!("newer-only-package"), "9"}])
    {:ok, view, _} = live(conn, "/?channel=#{channel.name}&rev=#{current.revision}")
    assert has_element?(view, "#dashboard-revision-summary", String.slice(current.revision, 0, 7))
    refute has_element?(view, "#dashboard-package-changes", "newer-only-package")
    assert has_element?(view, "#dashboard-package-changes", "alpha-changed")

    refute has_element?(
             view,
             "#dashboard-revision-summary",
             String.slice(previous.revision, 0, 7)
           )
  end

  test "signed in preview is actor scoped, bounded, and does not mark read or create a feed token",
       %{conn: conn} do
    user = register_user!()
    other = register_user!()
    channel = channel!()
    revision = channel_revision!(channel)

    notifications =
      for i <- 1..5 do
        notification!(user, %{
          channel_id: channel.id,
          channel_revision_id: revision.id,
          occurred_at: DateTime.add(~U[2026-09-01 00:00:00Z], i, :minute)
        })
      end

    hidden = notification!(other, %{channel_id: channel.id, channel_revision_id: revision.id})
    followed = change!(nil, %{title: "actor-owned followed change"})
    private = change!(nil, %{title: "another actor private subscription"})
    ChangeSubscription.subscribe!(followed.id, nil, actor: user)
    ChangeSubscription.subscribe!(private.id, nil, actor: other)
    {:ok, view, _} = live(log_in(conn, user), "/?channel=all")
    assert has_element?(view, "#dashboard-inbox", "5")
    assert length(nodes(view, "#dashboard-inbox [id^='notification-']")) == 3

    for notification <- Enum.take(Enum.reverse(notifications), 3) do
      assert has_element?(view, "#dashboard-inbox #notification-#{notification.id}")
    end

    refute has_element?(view, "#notification-#{hidden.id}")
    assert has_element?(view, "#dashboard-followed-changes .row-num", "##{followed.number}")
    refute has_element?(view, "#dashboard-followed-changes", private.title)
    assert has_element?(view, "#dashboard-inbox a[href*='/inbox']")
    assert has_element?(view, "#dashboard-followed-changes a[href*='/inbox/subscriptions']")
    assert Enum.all?(Notification.for_user!(actor: user), &is_nil(&1.read_at))
    assert Ash.get!(Tracker.Accounts.User, user.id, authorize?: false).feed_token == nil
  end

  test "all channels shows only configured roles in release order without concrete previews", %{
    conn: conn
  } do
    for {name, day} <- [
          {"nixos-unstable", 3},
          {"nixos-26.05", 1},
          {"nixos-unstable-small", 2},
          {"nixos-25.11", 4}
        ] do
      channel = channel!(name)

      channel_revision!(channel, %{
        revision: "dashboard-#{name}",
        released_at: DateTime.add(~U[2026-09-01 00:00:00Z], day, :day)
      })
    end

    {:ok, view, _} = live(conn, "/?channel=all")
    summaries = nodes(view, "#dashboard-revision-summary a[href*='/revisions/']")
    paths = Floki.attribute(summaries, "href")
    assert Enum.any?(paths, &String.contains?(&1, "/channels/nixos-unstable/revisions/"))
    assert Enum.any?(paths, &String.contains?(&1, "/channels/nixos-26.05/revisions/"))
    assert Enum.any?(paths, &String.contains?(&1, "/channels/nixos-unstable-small/revisions/"))
    refute Enum.any?(paths, &String.contains?(&1, "nixos-25.11"))

    text =
      view
      |> element("#dashboard-revision-summary")
      |> render()
      |> Floki.parse_document!()
      |> Floki.text()

    assert text =~ ~r/nixos-unstable.*nixos-unstable-small.*nixos-26.05/s
    refute has_element?(view, "#dashboard-package-changes")
    refute has_element?(view, "#dashboard-option-changes")
    refute has_element?(view, "#dashboard-inbox")
  end

  test "public recent changes sorts seven by GitHub update rather than merge dates", %{conn: conn} do
    changes =
      for i <- 1..9 do
        change!(nil, %{
          title: "recent-dashboard-#{i}",
          state: if(i == 9, do: :draft, else: if(i == 8, do: :open, else: :merged)),
          gh_updated_at: DateTime.add(~U[2026-09-01 00:00:00Z], i, :minute),
          merged_at: if(i >= 8, do: nil, else: ~U[2026-10-01 00:00:00Z])
        })
      end

    {:ok, view, _} = live(conn, "/?channel=all")
    rows = nodes(view, "#dashboard-recent-changes .row-num") |> Enum.map(&Floki.text/1)
    assert rows == changes |> Enum.reverse() |> Enum.take(7) |> Enum.map(&"##{&1.number}")
    assert has_element?(view, "#dashboard-recent-changes a[href*='/changes']", "View all")
    refute has_element?(view, "#dashboard-recent-changes", "recent-dashboard-1")
    refute has_element?(view, "#dashboard-recent-changes", "recent-dashboard-2")
  end

  test "no releases and a first revision render honest unavailable comparisons", %{conn: conn} do
    channel = channel!("nixos-26.05")
    {:ok, empty, _} = live(conn, "/?channel=#{channel.name}")
    refute has_element?(empty, "#dashboard-package-changes a[href*='/revisions/']")
    revision = channel_revision!(channel)
    {:ok, first, _} = live(conn, "/?channel=#{channel.name}")

    assert has_element?(
             first,
             "#dashboard-revision-summary",
             String.slice(revision.revision, 0, 7)
           )

    refute has_element?(first, "#dashboard-package-changes", "Version changed 0")
    refute has_element?(first, "#dashboard-option-changes", "Changed 0")
  end

  test "empty personal sections are still reachable without leaking public replacements", %{
    conn: conn
  } do
    {:ok, view, _} = live(log_in(conn, register_user!()), "/?channel=all")
    assert has_element?(view, "#dashboard-inbox")
    assert has_element?(view, "#dashboard-followed-changes")
    refute has_element?(view, "#dashboard-recent-changes")
    refute has_element?(view, "#dashboard-inbox [id^='notification-']")
    refute has_element?(view, "#dashboard-followed-changes .row-num")
  end

  test "connected inbox refreshes for own notifications but not another actor", %{conn: conn} do
    user = register_user!()
    other = register_user!()
    channel = channel!()
    revision = channel_revision!(channel)
    {:ok, view, _} = live(log_in(conn, user), "/?channel=all")
    own = notification!(user, %{channel_id: channel.id, channel_revision_id: revision.id})
    foreign = notification!(other, %{channel_id: channel.id, channel_revision_id: revision.id})
    assert has_element?(view, "#dashboard-inbox #notification-#{own.id}")
    refute has_element?(view, "#dashboard-inbox #notification-#{foreign.id}")
    assert Enum.all?(Notification.for_user!(actor: user), &is_nil(&1.read_at))
  end

  test "revision completion refreshes latest dashboard but preserves pinned comparison", %{
    conn: conn
  } do
    {channel, _previous, current} = comparison_fixture!()
    {:ok, latest, _} = live(conn, "/?channel=#{channel.name}")
    {:ok, pinned, _} = live(conn, "/?channel=#{channel.name}&rev=#{current.revision}")

    newer =
      channel_revision!(channel, %{
        revision: "ccccccc-dashboard-new",
        released_at: ~U[2026-09-03 00:00:00Z],
        previous_channel_revision_id: current.id
      })

    Tracker.Nixpkgs.ChannelRevision.record_result!(newer, %{result: :success})
    assert has_element?(latest, "#dashboard-revision-summary", "ccccccc")
    assert has_element?(pinned, "#dashboard-revision-summary", "bbbbbbb")
    refute has_element?(pinned, "#dashboard-revision-summary", "ccccccc")

    unrelated =
      channel_revision!(channel!(), %{
        revision: "ddddddd-unrelated-release",
        released_at: ~U[2026-09-04 00:00:00Z]
      })

    Tracker.Nixpkgs.ChannelRevision.record_result!(unrelated, %{result: :success})
    assert has_element?(latest, "#dashboard-revision-summary", "ccccccc")
    assert has_element?(pinned, "#dashboard-revision-summary", "bbbbbbb")
    refute has_element?(latest, "#dashboard-revision-summary", "ddddddd")
    refute has_element?(pinned, "#dashboard-revision-summary", "ddddddd")
  end

  test "followed arrival uses the concrete lens rather than the subscription target", %{
    conn: conn
  } do
    user = register_user!()
    displayed = channel!("nixos-26.05")
    target = channel!("nixos-unstable")
    displayed_revision = channel_revision!(displayed)
    target_revision = channel_revision!(target)
    arrived_elsewhere = change!(nil, %{title: "arrived only in subscription target"})
    arrived_here = change!(nil, %{title: "arrived in displayed channel"})
    open = change!(nil, %{state: :open, title: "open followed change"})
    ChangeSubscription.subscribe!(arrived_elsewhere.id, target.id, actor: user)
    ChangeSubscription.subscribe!(arrived_here.id, target.id, actor: user)
    ChangeSubscription.subscribe!(open.id, nil, actor: user)
    change_branch!(arrived_elsewhere, target.name, target_revision)
    change_branch!(arrived_here, displayed.name, displayed_revision)
    {:ok, view, _} = live(log_in(conn, user), "/?channel=#{displayed.name}")
    assert has_element?(view, "#dashboard-followed-changes .pill-open")
    assert length(nodes(view, "#dashboard-followed-changes .pill-landed")) == 1
    assert has_element?(view, "#dashboard-followed-changes .pill-landed", "in #{displayed.name}")
    refute has_element?(view, "#dashboard-followed-changes .pill-landed", "in #{target.name}")
  end

  test "followed changes are distinct and bounded even with multiple subscription scopes", %{
    conn: conn
  } do
    user = register_user!()
    channel = channel!()
    changes = for i <- 1..4, do: change!(nil, %{title: "followed bounded #{i}"})
    for change <- changes, do: ChangeSubscription.subscribe!(change.id, nil, actor: user)
    newest = List.last(changes)
    ChangeSubscription.subscribe!(newest.id, channel.id, actor: user)
    {:ok, view, _} = live(log_in(conn, user), "/?channel=all")
    rows = nodes(view, "#dashboard-followed-changes .row-num") |> Enum.map(&Floki.text/1)
    assert length(rows) == 3
    assert length(Enum.uniq(rows)) == 3
    assert hd(rows) == "##{newest.number}"
    assert has_element?(view, "#dashboard-followed-changes", "4")
  end

  test "absent configured channels are not replaced by another stable release", %{conn: conn} do
    other = channel!("nixos-25.11")
    revision = channel_revision!(other)
    {:ok, view, _} = live(conn, "/?channel=all")
    refute has_element?(view, "#dashboard-revision-summary", revision.revision)
    refute has_element?(view, "#dashboard-revision-summary a[href*='/channels/#{other.name}/']")
    assert has_element?(view, "#dashboard")
  end

  test "incomplete option data stays unavailable until independent options completion", %{
    conn: conn
  } do
    {channel, _previous, current} = comparison_fixture!()
    Tracker.Nixpkgs.ChannelRevision.record_options_result!(current, %{options_result: :error})
    {:ok, view, _} = live(conn, "/?channel=#{channel.name}")
    assert has_element?(view, "#dashboard-package-changes", "alpha-changed")
    refute has_element?(view, "#dashboard-option-changes a[href*='option_change=']")
    refute has_element?(view, "#dashboard-option-changes", "alpha.changed")
    Tracker.Nixpkgs.ChannelRevision.record_options_result!(current, %{options_result: :success})
    assert has_element?(view, "#dashboard-option-changes", "alpha.changed")
  end

  test "dashboard search navigates to packages and preserves concrete pinned lens", %{conn: conn} do
    {channel, _previous, current} = comparison_fixture!()
    {:ok, view, _} = live(conn, "/?channel=#{channel.name}&rev=#{current.revision}")
    assert has_element?(view, "form#page-search[action='/packages']")
    assert has_element?(view, "#page-search input[name='channel'][value='#{channel.name}']")
    assert has_element?(view, "#page-search input[name='rev'][value='#{current.revision}']")
  end

  test "default lens selects the real default stable release", %{conn: conn} do
    {channel, _previous, current} = comparison_fixture!()

    Tracker.Nixpkgs.Channel.create!(%{
      name: channel.name,
      display_name: channel.name,
      status: :active,
      is_stable: true
    })

    {:ok, view, _} = live(conn, "/")
    assert has_element?(view, "#dashboard-revision-summary", "bbbbbbb")

    assert has_element?(
             view,
             "#dashboard-revision-summary a[href*='/revisions/#{current.revision}']"
           )

    assert has_element?(view, "#dashboard-package-changes", "alpha-changed")
  end

  test "build problems come from current channel status even with a historical lens", %{
    conn: conn
  } do
    {channel, previous, _current} = comparison_fixture!()
    {:ok, healthy, _} = live(conn, "/?channel=#{channel.name}&rev=#{previous.revision}")
    refute has_element?(healthy, "#dashboard-revision-summary", "Build problem")
    Tracker.Nixpkgs.Channel.update_hydra_status!(channel, %{hydra_build_failed?: true})
    {:ok, problem, _} = live(conn, "/?channel=#{channel.name}&rev=#{previous.revision}")
    assert has_element?(problem, "#dashboard-revision-summary", "Build problem")
    assert has_element?(problem, "#dashboard-revision-summary", "Current channel")
  end

  test "preview fills missing types alphabetically without inventing additions or removals", %{
    conn: conn
  } do
    {channel, _previous, current} = comparison_fixture!()

    next =
      channel_revision!(channel, %{
        revision: "ccccccc-only-changed",
        released_at: ~U[2026-09-03 00:00:00Z],
        previous_channel_revision_id: current.id
      })

    packages =
      for name <- ["alpha-changed", "beta-changed", "omega-added"] do
        package = Tracker.Nixpkgs.Package.get_by_attribute!(name)
        {package, "4"}
      end

    apply_package_revision!(next, packages, complete?: true)
    Tracker.Nixpkgs.ChannelRevision.record_result!(next, %{result: :success})
    {:ok, view, _} = live(conn, "/?channel=#{channel.name}")

    text =
      view
      |> element("#dashboard-package-changes")
      |> render()
      |> Floki.parse_document!()
      |> Floki.text()

    assert text =~ ~r/alpha-changed.*beta-changed.*omega-added/s
    refute has_element?(view, "#dashboard-package-changes", "zulu-removed")
  end

  test "public recent changes include closed PRs and put missing GitHub update times last", %{
    conn: conn
  } do
    closed =
      change!(nil, %{
        state: :closed,
        title: "recent closed unmerged",
        gh_updated_at: ~U[2026-09-03 00:00:00Z]
      })

    missing = change!(nil, %{state: :draft, title: "missing update draft", gh_updated_at: nil})
    {:ok, view, _} = live(conn, "/?channel=all")

    assert nodes(view, "#dashboard-recent-changes .row-num") |> Enum.map(&Floki.text/1) == [
             "##{closed.number}",
             "##{missing.number}"
           ]

    assert has_element?(view, "#dashboard-recent-changes .pill-closed")
    assert has_element?(view, "#dashboard-recent-changes .pill-draft")
  end

  defp comparison_fixture! do
    channel = channel!("nixos-26.05")

    previous =
      channel_revision!(channel, %{
        revision: "aaaaaaa-dashboard-before",
        released_at: ~U[2026-09-01 00:00:00Z]
      })

    current =
      channel_revision!(channel, %{
        revision: "bbbbbbb-dashboard-current",
        released_at: ~U[2026-09-02 00:00:00Z],
        previous_channel_revision_id: previous.id
      })

    changed = package!("alpha-changed")
    extra = package!("beta-changed")
    removed = package!("zulu-removed")
    added = package!("omega-added")

    apply_package_revision!(previous, [{changed, "1"}, {extra, "1"}, {removed, "1"}],
      complete?: true
    )

    apply_package_revision!(current, [{changed, "2"}, {extra, "2"}, {added, "3"}],
      complete?: true
    )

    changed_option = option!("alpha.changed")
    extra_option = option!("beta.changed")
    removed_option = option!("zulu.removed")
    added_option = option!("omega.added")

    apply_option_revision!(
      previous,
      [
        {changed_option, %{type: "boolean"}},
        {extra_option, %{type: "boolean"}},
        {removed_option, %{type: "boolean"}}
      ],
      complete?: true
    )

    apply_option_revision!(
      current,
      [
        {changed_option, %{type: "string"}},
        {extra_option, %{type: "string"}},
        {added_option, %{type: "string"}}
      ],
      complete?: true
    )

    for revision <- [previous, current] do
      Tracker.Nixpkgs.ChannelRevision.record_result!(revision, %{result: :success})

      Tracker.Nixpkgs.ChannelRevision.record_options_result!(revision, %{options_result: :success})
    end

    {channel, previous, current}
  end

  defp nodes(view, selector),
    do: view |> render() |> Floki.parse_document!() |> Floki.find(selector)

  defp log_in(conn, user) do
    conn |> Plug.Test.init_test_session(%{}) |> Helpers.store_in_session(user)
  end
end

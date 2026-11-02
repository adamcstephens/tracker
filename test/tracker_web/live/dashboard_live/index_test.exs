defmodule TrackerWeb.DashboardLive.IndexTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tracker.Fixtures

  alias AshAuthentication.Plug.Helpers
  alias Tracker.Dashboard
  alias Tracker.Nixpkgs.{ChannelRevision, RevisionComparison, RevisionSummary}
  alias TrackerWeb.Lens
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

  test "nixpkgs revisions omit options while retaining package comparisons", %{conn: conn} do
    channel = channel!("nixpkgs-unstable")
    previous = channel_revision!(channel, %{released_at: ~U[2026-09-01 00:00:00Z]})

    current =
      channel_revision!(channel, %{
        released_at: ~U[2026-09-02 00:00:00Z],
        previous_channel_revision_id: previous.id
      })

    package = package!("dashboard-nixpkgs")
    apply_package_revision!(previous, [{package, "1"}], complete?: true)
    apply_package_revision!(current, [{package, "2"}], complete?: true)

    for revision <- [previous, current] do
      Tracker.Nixpkgs.ChannelRevision.record_result!(revision, %{result: :success})
    end

    current = ChannelRevision.get_by_id!(current.id)
    assert {:ok, _current} = RevisionSummary.persist(current)

    {:ok, view, _} = live(conn, "/?channel=#{channel.name}")
    assert has_element?(view, "#dashboard-revision-summary", "Packages")
    refute has_element?(view, "#dashboard-revision-summary", "Options")
    assert has_element?(view, "#dashboard-package-changes", package.attribute)
    refute has_element?(view, "#dashboard-option-changes")
    dashboard = Tracker.Dashboard.load(%TrackerWeb.Lens{channel: channel}, nil)
    assert dashboard.selected.status == :ready
    assert dashboard.selected.option_status == :not_applicable
    assert is_nil(dashboard.selected.option_counts)
    assert dashboard.selected.option_rows == []
  end

  test "nixpkgs channels without releases omit options", %{conn: conn} do
    channel = channel!("nixpkgs-unstable")
    {:ok, view, _} = live(conn, "/?channel=#{channel.name}")
    assert has_element?(view, "#dashboard-revision-summary", "Packages")
    refute has_element?(view, "#dashboard-revision-summary", "Options")
    refute has_element?(view, "#dashboard-option-changes")
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

  test "successful historical ingestion without stored summaries remains unavailable", %{
    conn: conn
  } do
    {channel, _previous, current} = comparison_fixture!(persist?: false)

    for suffix <- ["", "&rev=#{current.revision}"] do
      {:ok, view, _} = live(conn, "/?channel=#{channel.name}#{suffix}")
      dashboard = Dashboard.load(%Lens{channel: channel, revision: current}, nil)
      assert dashboard.selected.status == :incomplete
      assert dashboard.selected.package_status == :incomplete
      assert dashboard.selected.option_status == :incomplete
      assert is_nil(dashboard.selected.package_counts)
      assert is_nil(dashboard.selected.option_counts)
      assert dashboard.selected.package_rows == []
      assert dashboard.selected.option_rows == []
      refute has_element?(view, "#dashboard-revision-summary .dashboard-counts")
      assert has_element?(view, "#dashboard-revision-summary", "Comparison unavailable")
      assert has_element?(view, "#dashboard-package-changes", "Comparison unavailable")
      assert has_element?(view, "#dashboard-option-changes", "Comparison unavailable")
      refute has_element?(view, "#dashboard-package-changes", "alpha-changed")
      refute has_element?(view, "#dashboard-option-changes", "alpha.changed")
    end

    dashboard = Dashboard.load(%Lens{all?: true}, nil)
    [summary] = dashboard.channels
    assert summary.status == :incomplete
    assert is_nil(summary.package_counts)
    assert is_nil(summary.option_counts)
  end

  for {missing, available} <- [
        {:package_summary, :option_summary},
        {:option_summary, :package_summary}
      ] do
    @missing missing
    @available available
    test "missing #{@missing} does not hide the independently persisted #{@available}" do
      {channel, _previous, current} = comparison_fixture!()
      current = ChannelRevision.get_by_id!(current.id)
      ChannelRevision.record_summaries!(current, %{@missing => nil})
      dashboard = Dashboard.load(%Lens{channel: channel}, nil)

      assert dashboard.selected.status == :incomplete

      if @missing == :package_summary do
        assert dashboard.selected.package_status == :incomplete
        assert is_nil(dashboard.selected.package_counts)
        assert dashboard.selected.package_rows == []
        assert dashboard.selected.option_status == :ready
        assert dashboard.selected.option_counts.changed == 2
        assert Enum.any?(dashboard.selected.option_rows, &(&1.name == "alpha.changed"))
      else
        assert dashboard.selected.option_status == :incomplete
        assert is_nil(dashboard.selected.option_counts)
        assert dashboard.selected.option_rows == []
        assert dashboard.selected.package_status == :ready
        assert dashboard.selected.package_counts.changed == 2
        assert Enum.any?(dashboard.selected.package_rows, &(&1.attribute == "alpha-changed"))
      end
    end
  end

  test "stored counts and previews are authoritative for latest, pinned and all-channel reads", %{
    conn: conn
  } do
    {channel, _previous, current} = comparison_fixture!()
    current = ChannelRevision.get_by_id!(current.id)
    [package_row | _] = current.package_summary.results
    [option_row | _] = current.option_summary.results

    package_summary = %{
      current.package_summary
      | counts: %RevisionComparison.Counts{changed: 11, added: 13, removed: 17},
        results: [
          %{
            package_row
            | attribute: "stored-only-package",
              old_version: "saved-old",
              new_version: "saved-new"
          }
        ]
    }

    option_summary = %{
      current.option_summary
      | counts: %RevisionComparison.Counts{changed: 19, added: 23, removed: 29},
        results: [%{option_row | name: "stored.only.option"}]
    }

    ChannelRevision.record_summaries!(current, %{
      package_summary: package_summary,
      option_summary: option_summary
    })

    dashboard = Dashboard.load(%Lens{channel: channel}, nil)
    assert dashboard.selected.package_counts == package_summary.counts
    assert dashboard.selected.option_counts == option_summary.counts
    assert dashboard.selected.package_rows == package_summary.results
    assert dashboard.selected.option_rows == option_summary.results

    all = Dashboard.load(%Lens{all?: true}, nil)
    [summary] = all.channels
    assert summary.package_counts == package_summary.counts
    assert summary.option_counts == option_summary.counts
    assert summary.package_rows == []
    assert summary.option_rows == []

    newer =
      channel_revision!(channel, %{
        revision: "newer-without-summary",
        released_at: ~U[2026-09-03 00:00:00Z],
        previous_channel_revision_id: current.id
      })

    ChannelRevision.record_result!(newer, %{result: :success})
    ChannelRevision.record_options_result!(newer, %{options_result: :success})
    pinned = Dashboard.load(%Lens{channel: channel, revision: current}, nil)
    assert pinned.selected.package_counts == package_summary.counts
    assert pinned.selected.option_counts == option_summary.counts
    assert pinned.selected.package_rows == package_summary.results
    assert pinned.selected.option_rows == option_summary.results
    [latest] = pinned.channels
    assert is_nil(latest.package_counts)
    assert is_nil(latest.option_counts)

    {:ok, view, _} = live(conn, "/?channel=#{channel.name}&rev=#{current.revision}")
    assert has_element?(view, "#dashboard-package-changes", "stored-only-package")
    assert has_element?(view, "#dashboard-package-changes", "saved-old")
    assert has_element?(view, "#dashboard-package-changes", "saved-new")
    assert has_element?(view, "#dashboard-option-changes", "stored.only.option")
    refute has_element?(view, "#dashboard-package-changes", "alpha-changed")
    refute has_element?(view, "#dashboard-option-changes", "alpha.changed")
    assert has_element?(view, "#dashboard-revision-summary .dashboard-counts strong", "11")
    assert has_element?(view, "#dashboard-revision-summary .dashboard-counts strong", "19")
  end

  test "persisted zero summaries are ready rather than unavailable", %{conn: conn} do
    {channel, _previous, current} = comparison_fixture!()
    current = ChannelRevision.get_by_id!(current.id)

    ChannelRevision.record_summaries!(current, %{
      package_summary: %{
        current.package_summary
        | counts: %RevisionComparison.Counts{},
          results: []
      },
      option_summary: %{
        current.option_summary
        | counts: %RevisionComparison.Counts{},
          results: []
      }
    })

    dashboard = Dashboard.load(%Lens{channel: channel}, nil)
    assert dashboard.selected.status == :ready
    assert dashboard.selected.package_counts == %RevisionComparison.Counts{}
    assert dashboard.selected.option_counts == %RevisionComparison.Counts{}
    assert dashboard.selected.package_rows == []
    assert dashboard.selected.option_rows == []

    {:ok, view, _} = live(conn, "/?channel=#{channel.name}")

    assert has_element?(
             view,
             "#dashboard-package-changes",
             "No package changes in this revision."
           )

    assert has_element?(view, "#dashboard-option-changes", "No option changes in this revision.")
    refute has_element?(view, "#dashboard-revision-summary", "Comparison unavailable")
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
    assert has_element?(empty, "#dashboard-revision-summary", "No releases yet.")
    assert Dashboard.load(%Lens{channel: channel}, nil).selected.status == :no_release
    revision = channel_revision!(channel)
    {:ok, first, _} = live(conn, "/?channel=#{channel.name}")

    assert has_element?(
             first,
             "#dashboard-revision-summary",
             String.slice(revision.revision, 0, 7)
           )

    refute has_element?(first, "#dashboard-package-changes", "Version changed 0")
    refute has_element?(first, "#dashboard-option-changes", "Changed 0")
    assert has_element?(first, "#dashboard-revision-summary", "First known revision")
    assert Dashboard.load(%Lens{channel: channel}, nil).selected.status == :first_revision
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

    package = package!("completion-persisted-package")
    option = option!("completion.persisted.option")
    apply_package_revision!(newer, [{package, "8"}], complete?: true)
    apply_option_revision!(newer, [{option, %{type: "integer"}}], complete?: true)

    assert {:ok, newer} =
             RevisionSummary.persist(newer, %{newer | result: :success, options_result: :success})

    newer = ChannelRevision.record_result!(newer, %{result: :success})
    ChannelRevision.record_options_result!(newer, %{options_result: :success})
    assert has_element?(latest, "#dashboard-revision-summary", "ccccccc")
    assert has_element?(pinned, "#dashboard-revision-summary", "bbbbbbb")
    refute has_element?(pinned, "#dashboard-revision-summary", "ccccccc")
    assert has_element?(latest, "#dashboard-package-changes", package.attribute)
    assert has_element?(latest, "#dashboard-option-changes", option.name)
    assert has_element?(pinned, "#dashboard-package-changes", "alpha-changed")
    assert has_element?(pinned, "#dashboard-option-changes", "alpha.changed")
    refute has_element?(pinned, "#dashboard-package-changes", package.attribute)
    refute has_element?(pinned, "#dashboard-option-changes", option.name)

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
    {channel, _previous, current} = comparison_fixture!(persist?: false)
    current = ChannelRevision.record_options_result!(current, %{options_result: :error})
    assert {:ok, current} = RevisionSummary.persist(current)
    {:ok, view, _} = live(conn, "/?channel=#{channel.name}")
    assert has_element?(view, "#dashboard-package-changes", "alpha-changed")
    refute has_element?(view, "#dashboard-option-changes a[href*='option_change=']")
    refute has_element?(view, "#dashboard-option-changes", "alpha.changed")

    assert {:ok, current} =
             RevisionSummary.persist(current, %{current | options_result: :success})

    ChannelRevision.record_options_result!(current, %{options_result: :success})
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
    next = ChannelRevision.record_result!(next, %{result: :success})
    assert {:ok, _next} = RevisionSummary.persist(next)
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

  defp comparison_fixture!(opts \\ []) do
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

    current = ChannelRevision.get_by_id!(current.id)

    current =
      if Keyword.get(opts, :persist?, true) do
        assert {:ok, persisted} = RevisionSummary.persist(current)
        persisted
      else
        current
      end

    {channel, previous, current}
  end

  defp nodes(view, selector),
    do: view |> render() |> Floki.parse_document!() |> Floki.find(selector)

  defp log_in(conn, user) do
    conn |> Plug.Test.init_test_session(%{}) |> Helpers.store_in_session(user)
  end
end

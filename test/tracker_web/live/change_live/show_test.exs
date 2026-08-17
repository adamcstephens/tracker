defmodule TrackerWeb.ChangeLive.ShowTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup do
    maintainer =
      Tracker.Nixpkgs.Maintainer
      |> Ash.Changeset.for_create(:bulk_upsert, %{
        github_id: 4001,
        github: "showauthor"
      })
      |> Ash.create!()

    merger =
      Tracker.Nixpkgs.Maintainer
      |> Ash.Changeset.for_create(:bulk_upsert, %{
        github_id: 4002,
        github: "showmerger"
      })
      |> Ash.create!()

    id_map =
      Tracker.Nixpkgs.Change.bulk_upsert_all([
        %{
          number: 6001,
          title: "nixos/incus: add useACMEHost option",
          state: :merged,
          author: "showauthor",
          author_github_id: 4001,
          merged_by_github_id: 4002,
          url: "https://github.com/NixOS/nixpkgs/pull/6001",
          base_ref: "master",
          labels: ["6.topic: nixos", "10.rebuild-linux: 1-10"],
          merge_commit_sha: "abc123def456",
          gh_created_at: ~U[2026-03-28 16:15:06Z],
          merged_at: ~U[2026-03-31 01:57:58Z],
          package_count: 1,
          processing_status: :processed
        }
      ])

    pkg_map =
      Tracker.Nixpkgs.Package.bulk_upsert_all([%{attribute: "show-change-pkg"}])

    Tracker.Nixpkgs.ChangePackage.bulk_create_all([
      %{change_id: id_map[6001], package_id: pkg_map["show-change-pkg"], type: :changed}
    ])

    %{maintainer: maintainer, merger: merger}
  end

  test "renders change details", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/changes/6001")

    assert html =~ "6001"
    assert html =~ "nixos/incus: add useACMEHost option"
    assert html =~ "merged"
    assert html =~ "master"
    assert html =~ "abc123def456"
    assert html =~ "2026-03-31"
  end

  test "marks the PR anchor as the page's external link", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/changes/6001")

    assert [link | _] =
             html
             |> Floki.parse_document!()
             |> Floki.find("a[data-external-link]")

    assert Floki.attribute(link, "href") == ["https://github.com/NixOS/nixpkgs/pull/6001"]
    assert Floki.attribute(link, "target") == ["_blank"]
  end

  test "shows labels", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/changes/6001")

    assert html =~ "6.topic: nixos"
    assert html =~ "10.rebuild-linux: 1-10"
  end

  test "links author to maintainer page", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/changes/6001")

    assert html =~ "showauthor"
    assert html =~ "/maintainers/showauthor"
  end

  test "links merger to maintainer page", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/changes/6001")

    assert html =~ "showmerger"
    assert html =~ "/maintainers/showmerger"
  end

  test "shows affected packages", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/changes/6001")

    assert html =~ "Affected packages"
    assert html =~ "show-change-pkg"
  end

  test "the affected packages section uses the shared section header", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/changes/6001")

    assert has_element?(view, ".section-header h2", "Affected packages")
    assert has_element?(view, ".section-header .n", "1")
    refute has_element?(view, ".change-section-head")
  end

  test "affected packages render as shared row-list link rows", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/changes/6001")

    document = Floki.parse_document!(html)
    [list] = Floki.find(document, "#affected-packages")

    assert Floki.attribute(list, "class") == ["row-list"]
    assert Floki.attribute(list, "phx-update") == ["stream"]
    assert Floki.find(document, "table") == []

    [row] = Floki.find(list, "li")

    assert Floki.find(row, ~s(a.row-link[href="/packages/show-change-pkg"])) != []
    assert Floki.text(Floki.find(row, ".row-label")) =~ "show-change-pkg"
    assert Floki.attribute(row, "id") != []
  end

  test "hides the affected options section when no channel revision resolves", %{
    conn: conn
  } do
    {:ok, _view, html} = live(conn, ~p"/changes/6001")

    refute html =~ "Affected options"
  end

  # Names here (release line 99.99, `scoped.nix`, the `scoped*` option
  # namespaces) are unique to this file: channels, files and options are all
  # upserted on unique keys, so sharing a name with another async test
  # deadlocks the two transactions.
  describe "affected options scope" do
    setup do
      small = Tracker.Fixtures.channel!("nixos-99.99-small")

      small_cr =
        Tracker.Fixtures.channel_revision!(small, %{
          revision: "scopedsmall01",
          released_at: ~U[2026-04-01 10:00:00Z]
        })

      Tracker.Fixtures.load_options(
        %{
          "scopedsmall.opts.enable" => %{"declarations" => ["scoped.nix"]},
          "scopedsmall.opts.user" => %{"declarations" => ["scoped.nix"]}
        },
        small_cr
      )

      Tracker.Nixpkgs.ChannelRevision.record_options_result!(small_cr, %{
        options_result: :success
      })

      full = Tracker.Fixtures.channel!("nixos-99.99")

      full_cr =
        Tracker.Fixtures.channel_revision!(full, %{
          revision: "scopedfull001",
          released_at: ~U[2026-04-02 10:00:00Z]
        })

      Tracker.Fixtures.load_options(
        %{"scopedfull.opts.enable" => %{"declarations" => ["scoped.nix"]}},
        full_cr
      )

      Tracker.Nixpkgs.ChannelRevision.record_options_result!(full_cr, %{
        options_result: :success
      })

      Tracker.Fixtures.channel!("nixos-98.98")

      change =
        Tracker.Fixtures.change!(6002, %{
          base_ref: "release-99.99",
          processing_status: :processed
        })

      Tracker.Nixpkgs.ChangeFile.bulk_insert_all([
        %{change_id: change.id, file_id: Tracker.Nixpkgs.File.get_by_path!("scoped.nix").id}
      ])

      %{change: change, full: full, full_cr: full_cr}
    end

    test "scopes to the first channel downstream of base_ref when the change has not landed in the lens channel",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/changes/6002?channel=nixos-98.98")

      assert html =~ "Affected options"
      assert html =~ "scopedsmall.opts"
      refute html =~ "scopedfull.opts"
    end

    test "scopes to the lens channel once the change has landed there", %{
      conn: conn,
      change: change,
      full_cr: full_cr
    } do
      Tracker.Fixtures.change_branch!(change, "nixos-99.99", full_cr)

      {:ok, _view, html} = live(conn, ~p"/changes/6002?channel=nixos-99.99")

      assert html =~ "scopedfull.opts"
      refute html =~ "scopedsmall.opts"
    end

    test "honours the lens revision pin on a channel the change has landed in", %{
      conn: conn,
      change: change,
      full: full,
      full_cr: full_cr
    } do
      Tracker.Fixtures.change_branch!(change, "nixos-99.99", full_cr)

      later_cr =
        Tracker.Fixtures.channel_revision!(full, %{
          revision: "scopedfull002",
          released_at: ~U[2026-04-03 10:00:00Z]
        })

      Tracker.Fixtures.load_options(%{}, later_cr)

      Tracker.Nixpkgs.ChannelRevision.record_options_result!(later_cr, %{
        options_result: :success
      })

      {:ok, _view, html} =
        live(conn, ~p"/changes/6002?channel=nixos-99.99&rev=scopedfull001")

      assert html =~ "scopedfull.opts"

      {:ok, _view, html} = live(conn, ~p"/changes/6002?channel=nixos-99.99")

      refute html =~ "scopedfull.opts"
    end

    test "switching the lens reloads the page under the new channel", %{
      conn: conn,
      change: change,
      full_cr: full_cr
    } do
      Tracker.Fixtures.change_branch!(change, "nixos-99.99", full_cr)

      {:ok, view, html} = live(conn, ~p"/changes/6002?channel=nixos-98.98")

      assert html =~ "scopedsmall.opts"

      {:ok, _view, html} = switch_lens(conn, view, "nixos-99.99")

      assert html =~ "scopedfull.opts"
      refute html =~ "scopedsmall.opts"
    end
  end

  describe "files_over_limit notice" do
    setup do
      Tracker.Nixpkgs.Change.get_by_number!(6001)
      |> Tracker.Nixpkgs.Change.set_files_over_limit!(%{files_over_limit: true})

      :ok
    end

    test "renders a too-many-files notice when files_over_limit is true", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/changes/6001")

      assert html =~ "too many files"
    end

    test "hides the affected options section even when a lens revision is resolvable", %{
      conn: conn
    } do
      Tracker.Nixpkgs.Channel.create!(%{
        name: "nixos-lens-channel",
        display_name: "nixos-lens-channel",
        status: :active,
        is_stable: false
      })
      |> then(fn channel ->
        cr =
          Tracker.Nixpkgs.ChannelRevision.create!(%{
            channel_id: channel.id,
            revision: "limnotice0011",
            released_at: ~U[2026-04-01 10:00:00Z]
          })

        Tracker.Nixpkgs.ChannelRevision.record_options_result!(cr, %{options_result: :success})
      end)

      {:ok, _view, html} = live(conn, ~p"/changes/6001?channel=nixos-lens-channel")

      refute html =~ "Affected options"
    end
  end

  test "links to github PR", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/changes/6001")

    assert html =~ "https://github.com/NixOS/nixpkgs/pull/6001"
  end

  test "links to merge commit", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/changes/6001")

    assert html =~ "https://github.com/NixOS/nixpkgs/commit/abc123def456"
  end

  describe "propagation lifecycle section" do
    test "renders the DAG rooted at the change's base_ref", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/changes/6001")

      assert html =~ "Propagation"
      assert html =~ ~s|data-branch="master"|
      assert html =~ ~s|data-branch="nixpkgs-unstable"|
      assert html =~ ~s|data-branch="nixos-unstable-small"|
      assert html =~ ~s|data-branch="nixos-unstable"|
    end

    test "renders the mobile branch tree alongside the desktop DAG", %{conn: conn} do
      change_id = Tracker.Nixpkgs.Change.get_by_number!(6001).id

      Tracker.Nixpkgs.ChangeBranch.create!(%{change_id: change_id, branch_name: "master"})

      {:ok, _view, html} = live(conn, ~p"/changes/6001")

      assert html =~ ~s|class="m4-tree"|
      assert html =~ ~r/<li[^>]*class="is-done"[^>]*data-branch="master"/

      assert html =~ ~s|data-branch="nixos-unstable"|
      refute html =~ ~r/<li[^>]*class="is-done"[^>]*data-branch="nixos-unstable"/
    end

    test "marks branches with a ChangeBranch as present", %{conn: conn} do
      change_id = Tracker.Nixpkgs.Change.get_by_number!(6001).id

      Tracker.Nixpkgs.ChangeBranch.create!(%{change_id: change_id, branch_name: "master"})

      Tracker.Nixpkgs.ChangeBranch.create!(%{
        change_id: change_id,
        branch_name: "nixpkgs-unstable"
      })

      {:ok, _view, html} = live(conn, ~p"/changes/6001")

      assert html =~ ~r/class="[^"]*propagation-node-present[^"]*"[^>]*data-branch="master"/

      assert html =~
               ~r/class="[^"]*propagation-node-present[^"]*"[^>]*data-branch="nixpkgs-unstable"/

      assert html =~
               ~r/class="[^"]*propagation-node-pending[^"]*"[^>]*data-branch="nixos-unstable"/
    end

    test "links present branches with a channel_revision to the revision show page", %{
      conn: conn
    } do
      change_id = Tracker.Nixpkgs.Change.get_by_number!(6001).id

      channel =
        Tracker.Nixpkgs.Channel.create!(%{
          name: "nixpkgs-unstable",
          display_name: "nixpkgs-unstable",
          status: :active
        })

      revision =
        Tracker.Nixpkgs.ChannelRevision.create!(%{
          channel_id: channel.id,
          revision: "deadbeefcafef00d1234567890abcdef12345678",
          released_at: ~U[2026-04-01 12:00:00Z]
        })

      Tracker.Nixpkgs.ChangeBranch.create!(%{
        change_id: change_id,
        branch_name: "nixpkgs-unstable",
        channel_revision_id: revision.id
      })

      {:ok, _view, html} = live(conn, ~p"/changes/6001")

      assert html =~
               ~s|href="/channels/nixpkgs-unstable/revisions/deadbeefcafef00d1234567890abcdef12345678"|
    end

    test "hides the section when base_ref is not a known propagation branch", %{conn: conn} do
      Tracker.Nixpkgs.Change.bulk_upsert_all([
        %{
          number: 6002,
          title: "branch-less change",
          state: :open,
          author: "x",
          url: "https://github.com/NixOS/nixpkgs/pull/6002",
          base_ref: "feature-branch",
          processing_status: :pending
        }
      ])

      {:ok, _view, html} = live(conn, ~p"/changes/6002")

      refute html =~ "Propagation"
      refute html =~ "propagation-dag"
    end
  end

  describe "mobile M4 chrome" do
    test "renders chip row + title with mobile classes", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/changes/6001")

      assert html =~ ~s|class="change-head-row cm-headrow"|
      assert html =~ ~s|<code class="cm-base">master</code>|
      assert html =~ ~s|class="cm-title"|
    end

    test "renders the m4 progress band with landed counts and merged-ago text", %{conn: conn} do
      change_id = Tracker.Nixpkgs.Change.get_by_number!(6001).id
      Tracker.Nixpkgs.ChangeBranch.create!(%{change_id: change_id, branch_name: "master"})

      {:ok, _view, html} = live(conn, ~p"/changes/6001")

      assert html =~ ~s|class="m4-prop-num"|
      assert html =~ "channels reached"
      assert html =~ ~s|class="m4-prop-bar"|
      assert html =~ ~r/class="m4-prop-foot"[^>]*>\s*merged/
    end

    test "renders the segmented tabs with four panels", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/changes/6001")

      assert html =~ ~s|class="m3-tabs"|
      assert html =~ ~s|class="m3-panel m3-panel-chans"|
      assert html =~ ~s|class="m3-panel m3-panel-pkgs"|
      assert html =~ ~s|class="m3-panel m3-panel-opts"|
      assert html =~ ~s|class="m3-panel m3-panel-info"|

      tab_labels = Regex.scan(~r/<label[^>]*for="cmtab-[^"]+"/, html) |> length()
      assert tab_labels == 4

      assert html =~
               ~r/<input type="radio" name="cmtab-6001"[^>]*class="m4tab m4tab-chans"[^>]*checked/
    end
  end

  describe "default tab selection" do
    test "defaults to Info when the PR is not merged", %{conn: conn} do
      Tracker.Nixpkgs.Change.bulk_upsert_all([
        %{
          number: 6201,
          title: "open pr",
          state: :open,
          author: "x",
          url: "https://github.com/NixOS/nixpkgs/pull/6201",
          base_ref: "master",
          processing_status: :pending
        }
      ])

      {:ok, _view, html} = live(conn, ~p"/changes/6201")

      assert html =~
               ~r/<input type="radio" name="cmtab-6201"[^>]*class="m4tab m4tab-info"[^>]*checked/

      refute html =~
               ~r/<input type="radio" name="cmtab-6201"[^>]*class="m4tab m4tab-chans"[^>]*checked/
    end

    test "defaults to Packages when package_search is in the URL", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/changes/6001?package_search=show")

      assert html =~
               ~r/<input type="radio" name="cmtab-6001"[^>]*class="m4tab m4tab-pkgs"[^>]*checked/

      refute html =~
               ~r/<input type="radio" name="cmtab-6001"[^>]*class="m4tab m4tab-chans"[^>]*checked/
    end

    test "ignores package_search default when packages are disabled", %{conn: conn} do
      Tracker.Nixpkgs.Change.bulk_upsert_all([
        %{
          number: 6202,
          title: "merged but no packages",
          state: :merged,
          author: "x",
          url: "https://github.com/NixOS/nixpkgs/pull/6202",
          base_ref: "master",
          merge_commit_sha: "abc",
          merged_at: ~U[2026-04-01 12:00:00Z],
          package_count: 0,
          processing_status: :processed
        }
      ])

      {:ok, _view, html} = live(conn, ~p"/changes/6202?package_search=show")

      refute html =~
               ~r/<input type="radio" name="cmtab-6202"[^>]*class="m4tab m4tab-pkgs"[^>]*checked/

      assert html =~
               ~r/<input type="radio" name="cmtab-6202"[^>]*class="m4tab m4tab-chans"[^>]*checked/
    end
  end

  describe "live updates" do
    test "re-renders when the change is updated via notifier", %{conn: conn} do
      Tracker.Nixpkgs.Change.bulk_upsert_all([
        %{
          number: 6100,
          title: "still open",
          state: :open,
          author: "openauthor",
          url: "https://github.com/NixOS/nixpkgs/pull/6100",
          base_ref: "master",
          processing_status: :pending
        }
      ])

      {:ok, view, html} = live(conn, ~p"/changes/6100")
      assert html =~ "pill-open"

      change = Tracker.Nixpkgs.Change.get_by_number!(6100)

      Tracker.Nixpkgs.Change.refresh_from_graphql!(change, %{
        state: :merged,
        merged_at: ~U[2026-04-01 12:00:00Z],
        merge_commit_sha: "feedfacefeed"
      })

      html = render(view)
      assert html =~ "pill-merged"
      assert html =~ "feedfacefeed"
    end

    test "ignores notifications for other changes", %{conn: conn} do
      Tracker.Nixpkgs.Change.bulk_upsert_all([
        %{
          number: 6101,
          title: "other change",
          state: :open,
          author: "x",
          url: "https://github.com/NixOS/nixpkgs/pull/6101",
          base_ref: "master",
          processing_status: :pending
        }
      ])

      {:ok, view, _html} = live(conn, ~p"/changes/6001")

      other = Tracker.Nixpkgs.Change.get_by_number!(6101)

      Tracker.Nixpkgs.Change.refresh_from_graphql!(other, %{
        state: :merged,
        merged_at: ~U[2026-04-01 12:00:00Z],
        merge_commit_sha: "deadbeefdead"
      })

      html = render(view)
      refute html =~ "deadbeefdead"
      refute html =~ "other change"
    end

    test "re-renders propagation DAG when a ChangeBranch is created", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/changes/6001")

      refute html =~ ~r/class="[^"]*propagation-node-present[^"]*"[^>]*data-branch="master"/

      change_id = Tracker.Nixpkgs.Change.get_by_number!(6001).id
      Tracker.Nixpkgs.ChangeBranch.create!(%{change_id: change_id, branch_name: "master"})

      html = render(view)
      assert html =~ ~r/class="[^"]*propagation-node-present[^"]*"[^>]*data-branch="master"/
    end

    test "ignores ChangeBranch notifications for other changes", %{conn: conn} do
      Tracker.Nixpkgs.Change.bulk_upsert_all([
        %{
          number: 6102,
          title: "another change",
          state: :merged,
          author: "x",
          url: "https://github.com/NixOS/nixpkgs/pull/6102",
          base_ref: "master",
          merge_commit_sha: "cafef00dcafe",
          merged_at: ~U[2026-04-01 12:00:00Z],
          processing_status: :processed
        }
      ])

      {:ok, view, _html} = live(conn, ~p"/changes/6001")

      other_id = Tracker.Nixpkgs.Change.get_by_number!(6102).id
      Tracker.Nixpkgs.ChangeBranch.create!(%{change_id: other_id, branch_name: "master"})

      html = render(view)
      refute html =~ ~r/class="[^"]*propagation-node-present[^"]*"[^>]*data-branch="master"/
    end

    test "rebuilds the mobile propagation tree when the lens changes", %{conn: conn} do
      Tracker.Nixpkgs.Channel.create!(%{
        name: "nixpkgs-unstable",
        display_name: "nixpkgs-unstable",
        status: :active,
        is_stable: false
      })

      Tracker.Nixpkgs.Channel.create!(%{
        name: "nixos-unstable",
        display_name: "nixos-unstable",
        status: :active,
        is_stable: false
      })

      {:ok, view, html} =
        live(conn, ~p"/changes/6001?channel=nixpkgs-unstable")

      assert html =~ ~r/<li[^>]*class="[^"]*is-mine[^"]*"[^>]*data-branch="nixpkgs-unstable"/
      refute html =~ ~r/<li[^>]*class="[^"]*is-mine[^"]*"[^>]*data-branch="nixos-unstable"/

      {:ok, _view, html} = switch_lens(conn, view, "nixos-unstable")

      assert html =~ ~r/<li[^>]*class="[^"]*is-mine[^"]*"[^>]*data-branch="nixos-unstable"/
      refute html =~ ~r/<li[^>]*class="[^"]*is-mine[^"]*"[^>]*data-branch="nixpkgs-unstable"/
    end
  end
end

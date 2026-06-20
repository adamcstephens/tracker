defmodule TrackerWeb.ChangeLive.ShowTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  require Ash.Query

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

  describe "affected options section" do
    # P3 (trk-322): option setup uses the removed option-revision model.
    @describetag :skip
    setup do
      change_id = Tracker.Nixpkgs.Change.get_by_number!(6001).id

      channel =
        Tracker.Nixpkgs.Channel.create!(%{
          name: "nixos-unstable-opts",
          display_name: "nixos-unstable-opts",
          status: :active,
          is_stable: false
        })

      cr =
        Tracker.Nixpkgs.ChannelRevision.create!(%{
          channel_id: channel.id,
          revision: "optaffect001122",
          released_at: ~U[2026-04-01 10:00:00Z]
        })

      cr = Tracker.Nixpkgs.ChannelRevision.record_options_result!(cr, %{options_result: :success})

      %{"nixos/modules/services/web-servers/nginx/default.nix" => file_id} =
        Tracker.Nixpkgs.File.bulk_upsert_all([
          "nixos/modules/services/web-servers/nginx/default.nix"
        ])

      Tracker.Nixpkgs.ChangeFile.bulk_insert_all([%{change_id: change_id, file_id: file_id}])

      for {name, loc} <- [
            {"services.nginx.enable", ["services", "nginx", "enable"]},
            {"services.nginx.virtualHosts", ["services", "nginx", "virtualHosts"]}
          ] do
        %{^name => opt_id} = Tracker.Nixpkgs.Option.bulk_upsert_all([%{name: name}])

        %{^opt_id => rev_id} =
          Tracker.Nixpkgs.OptionRevision.bulk_insert_all([
            %{
              option_id: opt_id,
              channel_revision_id: cr.id,
              description: "doc for #{name}",
              type: "boolean",
              default: "false",
              example: nil,
              read_only: false,
              loc: loc,
              related_packages: nil
            }
          ])

        Tracker.Nixpkgs.OptionRevisionFile.bulk_insert_all([
          %{option_revision_id: rev_id, file_id: file_id}
        ])
      end

      :ok
    end

    test "renders affected options as a Namespace table linking to /options/<prefix>",
         %{conn: conn} do
      {:ok, _view, html} =
        live(conn, ~p"/changes/6001?lens_channel=nixos-unstable-opts")

      assert html =~ "Affected options"
      assert html =~ ">Namespace<"
      assert html =~ ~s|href="/options/services.nginx"|
      # The full option name is no longer rendered as its own row.
      refute html =~ ~s|href="/options/services.nginx.enable"|
    end
  end

  describe "affected options cap" do
    # P3 (trk-322): option setup uses the removed option-revision model.
    @describetag :skip
    setup do
      change_id = Tracker.Nixpkgs.Change.get_by_number!(6001).id

      channel =
        Tracker.Nixpkgs.Channel.create!(%{
          name: "nixos-cap-test",
          display_name: "nixos-cap-test",
          status: :active,
          is_stable: false
        })

      cr =
        Tracker.Nixpkgs.ChannelRevision.create!(%{
          channel_id: channel.id,
          revision: "capabc000111",
          released_at: ~U[2026-04-01 10:00:00Z]
        })

      cr = Tracker.Nixpkgs.ChannelRevision.record_options_result!(cr, %{options_result: :success})

      %{"nixos/modules/foundational.nix" => file_id} =
        Tracker.Nixpkgs.File.bulk_upsert_all(["nixos/modules/foundational.nix"])

      Tracker.Nixpkgs.ChangeFile.bulk_insert_all([%{change_id: change_id, file_id: file_id}])

      # 25 distinct two-segment prefixes, single option each → exceeds the 20 cap.
      for i <- 1..25 do
        name = "namespace#{:io_lib.format("~2..0B", [i]) |> List.to_string()}.section.leaf"
        %{^name => opt_id} = Tracker.Nixpkgs.Option.bulk_upsert_all([%{name: name}])

        %{^opt_id => rev_id} =
          Tracker.Nixpkgs.OptionRevision.bulk_insert_all([
            %{
              option_id: opt_id,
              channel_revision_id: cr.id,
              description: "x",
              type: "boolean",
              default: "false",
              example: nil,
              read_only: false,
              loc: ["x"],
              related_packages: nil
            }
          ])

        Tracker.Nixpkgs.OptionRevisionFile.bulk_insert_all([
          %{option_revision_id: rev_id, file_id: file_id}
        ])
      end

      :ok
    end

    test "caps the rendered list at 20 and shows an …and N more hint", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/changes/6001?lens_channel=nixos-cap-test")

      assert html =~ "Affected options"
      # Total goes in the heading
      assert html =~ "Affected options <small class=\"muted\">(25)</small>"
      # Tail hint shows the 5 prefixes that didn't make the cap
      assert html =~ "and 5 more namespaces"

      prefix_links =
        Regex.scan(~r|href="/options/namespace\d+\.section"|, html) |> length()

      assert prefix_links == 20
    end
  end

  test "hides the affected options section when there is no resolvable lens revision", %{
    conn: conn
  } do
    {:ok, _view, html} = live(conn, ~p"/changes/6001")

    refute html =~ "Affected options"
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

      {:ok, _view, html} = live(conn, ~p"/changes/6001?lens_channel=nixos-lens-channel")

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
        live(conn, ~p"/changes/6001?lens_channel=nixpkgs-unstable")

      assert html =~ ~r/<li[^>]*class="[^"]*is-mine[^"]*"[^>]*data-branch="nixpkgs-unstable"/
      refute html =~ ~r/<li[^>]*class="[^"]*is-mine[^"]*"[^>]*data-branch="nixos-unstable"/

      send(view.pid, {:set_lens, "nixos-unstable", ""})

      html = render(view)

      assert html =~ ~r/<li[^>]*class="[^"]*is-mine[^"]*"[^>]*data-branch="nixos-unstable"/
      refute html =~ ~r/<li[^>]*class="[^"]*is-mine[^"]*"[^>]*data-branch="nixpkgs-unstable"/
    end
  end
end

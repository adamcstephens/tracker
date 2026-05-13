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
      Tracker.Nixpkgs.Package.bulk_upsert_all([
        %{attribute: "show-change-pkg", description: "A test package"}
      ])

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
  end
end

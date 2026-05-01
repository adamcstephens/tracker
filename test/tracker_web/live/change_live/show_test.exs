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

    assert html =~ "Affected Packages"
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

  describe "affected options section" do
    setup do
      channel =
        Tracker.Nixpkgs.Channel.create!(%{
          name: "nixos-unstable",
          display_name: "NixOS Unstable",
          branch: "nixos-unstable",
          status: :active,
          is_stable: true
        })

      cr =
        Tracker.Nixpkgs.ChannelRevision.create!(%{
          channel_id: channel.id,
          revision: "showrevopts0001",
          released_at: ~U[2026-04-01 10:00:00Z]
        })

      Tracker.Nixpkgs.ChannelRevision.record_result!(cr, %{result: :success})

      cr =
        Tracker.Nixpkgs.ChannelRevision.record_options_result!(cr, %{options_result: :success})

      Tracker.Fixtures.load_options(
        %{
          "services.nginx.enable" => %{
            "declarations" => ["nixos/modules/services/web-servers/nginx/default.nix"],
            "description" => "Enable Nginx.",
            "loc" => ["services", "nginx", "enable"],
            "readOnly" => false,
            "type" => "boolean"
          },
          "services.nginx.user" => %{
            "declarations" => ["nixos/modules/services/web-servers/nginx/default.nix"],
            "description" => "User to run Nginx as.",
            "loc" => ["services", "nginx", "user"],
            "readOnly" => false,
            "type" => "string"
          },
          "boot.kernelPackages" => %{
            "declarations" => ["nixos/modules/system/boot/kernel.nix"],
            "description" => "Kernel.",
            "loc" => ["boot", "kernelPackages"],
            "readOnly" => false,
            "type" => "string"
          }
        },
        cr
      )

      change_id = Tracker.Nixpkgs.Change.get_by_number!(6001).id

      [nginx_file, _kernel_file] =
        Tracker.Nixpkgs.File
        |> Ash.Query.filter(
          path in [
            "nixos/modules/services/web-servers/nginx/default.nix",
            "nixos/modules/system/boot/kernel.nix"
          ]
        )
        |> Ash.Query.sort(path: :asc)
        |> Ash.read!()

      Tracker.Nixpkgs.ChangeFile.bulk_insert_all([
        %{change_id: change_id, file_id: nginx_file.id}
      ])

      :ok
    end

    test "lists folded prefixes from options touched via change_files", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/changes/6001")

      assert html =~ "Affected options"
      assert html =~ "services.nginx"
      assert html =~ "(2 options)"
      refute html =~ "boot.kernelPackages"
    end
  end

  test "Affected options section omitted when no change_files", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/changes/6001")

    refute html =~ "Affected options"
  end
end

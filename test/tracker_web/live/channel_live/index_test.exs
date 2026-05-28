defmodule TrackerWeb.ChannelLive.IndexTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Tracker.Nixpkgs.Channel

  setup do
    channel_unstable =
      Channel.create!(%{
        name: "nixos-unstable",
        display_name: "NixOS Unstable",
        status: :active,
        is_stable: false
      })

    channel_stable =
      Channel.create!(%{
        name: "nixos-24.11",
        display_name: "NixOS 24.11",
        status: :active,
        is_stable: true
      })

    channel_pre_release =
      Channel.create!(%{
        name: "nixos-26.05",
        display_name: "NixOS 26.05",
        status: :pre_release,
        is_stable: true
      })

    Ash.create!(Tracker.Nixpkgs.ChannelRevision, %{
      channel_id: channel_unstable.id,
      revision: "aaa111bbb222ccc",
      released_at: ~U[2026-03-01 10:00:00Z]
    })

    Ash.create!(Tracker.Nixpkgs.ChannelRevision, %{
      channel_id: channel_unstable.id,
      revision: "ddd333eee444fff",
      released_at: ~U[2026-03-15 10:00:00Z]
    })

    Ash.create!(Tracker.Nixpkgs.ChannelRevision, %{
      channel_id: channel_stable.id,
      revision: "ggg555hhh666iii",
      released_at: ~U[2026-03-10 10:00:00Z]
    })

    Ash.create!(Tracker.Nixpkgs.ChannelRevision, %{
      channel_id: channel_pre_release.id,
      revision: "jjj777kkk888lll",
      released_at: ~U[2026-03-12 10:00:00Z]
    })

    :ok
  end

  test "renders channel list with revision counts", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/channels")

    assert html =~ "nixos-unstable"
    assert html =~ "nixos-24.11"
  end

  test "clicking sort header changes order", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/channels")

    view |> element("th[phx-value-field=name]") |> render_click()
    assert_patched(view, ~p"/channels?sort_by=name&sort_dir=asc")
  end

  test "renders a Build problem badge for channels whose hydra job failed", %{conn: conn} do
    channel = Channel.by_name!("nixos-unstable")

    {:ok, _} =
      Channel.update_hydra_status(channel, %{
        hydra_build_failed?: true,
        hydra_project: "nixos",
        hydra_jobset: "unstable",
        hydra_exported_job: "tested"
      })

    {:ok, _view, html} = live(conn, ~p"/channels")

    assert html =~ "Build problem"
    assert html =~ "https://hydra.nixos.org/jobset/nixos/unstable"
  end

  test "does not render Build problem for healthy channels", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/channels")
    refute html =~ "Build problem"
  end

  test "Build problem badge appears live without a reload", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/channels")
    refute html =~ "Build problem"

    channel = Channel.by_name!("nixos-unstable")

    {:ok, _} =
      Channel.update_hydra_status(channel, %{
        hydra_build_failed?: true,
        hydra_project: "nixos",
        hydra_jobset: "unstable",
        hydra_exported_job: "tested"
      })

    html = render(view)
    assert html =~ "Build problem"
    assert html =~ "https://hydra.nixos.org/jobset/nixos/unstable"
  end

  test "revision count and latest release update live when a revision is created", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/channels")
    refute html =~ "2026-04-02"

    channel = Channel.by_name!("nixos-unstable")

    Ash.create!(Tracker.Nixpkgs.ChannelRevision, %{
      channel_id: channel.id,
      revision: "live111aaa222333",
      released_at: ~U[2026-04-02 09:00:00Z]
    })

    html = render(view)
    assert html =~ "2026-04-02"
  end

  test "renders Pre-release badge for channels in pre_release status", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/channels")

    assert html =~ "nixos-26.05"
    assert html =~ "Pre-release"
  end
end

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
end

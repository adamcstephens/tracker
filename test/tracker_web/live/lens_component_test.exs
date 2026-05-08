defmodule TrackerWeb.LensComponentTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Tracker.Nixpkgs.Channel

  setup do
    suffix = System.unique_integer([:positive])

    stable =
      Channel.create!(%{
        name: "nixos-25.#{suffix}",
        display_name: "NixOS 25.#{suffix}",
        status: :active,
        is_stable: true
      })

    unstable =
      Channel.create!(%{
        name: "nixos-unstable-#{suffix}",
        display_name: "NixOS Unstable #{suffix}",
        status: :active,
        is_stable: false
      })

    %{stable: stable, unstable: unstable}
  end

  test "renders channel selector with active channels", %{
    conn: conn,
    stable: stable,
    unstable: unstable
  } do
    {:ok, _view, html} = live(conn, ~p"/packages")

    assert html =~ stable.name
    assert html =~ unstable.name
    assert html =~ ~s(id="lens")
  end

  test "current lens channel is selected", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/packages")

    # Default stable should be selected
    assert html =~ ~s(selected)
  end

  test "renders divided pill with Channel label", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/packages")

    assert html =~ ~s(class="lens-label")
    assert html =~ "Channel"
  end

  test "does not render a Rev toggle button or rev input", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/packages")

    refute html =~ ~s(>Rev</button)
    refute html =~ ~s(name="rev")
  end

  test "renders 'All channels' option in dropdown", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/packages")

    assert html =~ ~s(value="all")
    assert html =~ "All channels"
  end

  test "renders short revision when lens has a revision set", %{conn: conn} do
    suffix = System.unique_integer([:positive])

    channel =
      Channel.create!(%{
        name: "nixos-rev-#{suffix}",
        display_name: "NixOS Rev #{suffix}",
        status: :active,
        is_stable: false
      })

    rev_hash = "abcdef1234567890"

    Tracker.Nixpkgs.ChannelRevision
    |> Ash.Changeset.for_create(:create, %{
      channel_id: channel.id,
      revision: rev_hash,
      released_at: ~U[2025-06-01 00:00:00Z]
    })
    |> Ash.create!()

    token =
      Phoenix.Token.sign(
        TrackerWeb.Endpoint,
        TrackerWeb.Lens.cookie_salt(),
        "#{channel.name}:#{rev_hash}"
      )

    conn = put_req_cookie(conn, "_tracker_lens", token)

    {:ok, _view, html} = live(conn, ~p"/packages")

    assert html =~ ~s(class="lens-rev")
    assert html =~ "@abcdef1"
  end
end

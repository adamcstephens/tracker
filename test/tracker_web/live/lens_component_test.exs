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
        branch: "release-25.#{suffix}",
        status: :active,
        is_stable: true
      })

    unstable =
      Channel.create!(%{
        name: "nixos-unstable-#{suffix}",
        display_name: "NixOS Unstable #{suffix}",
        branch: "nixos-unstable-#{suffix}",
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

  test "renders rev toggle button", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/packages")

    assert html =~ "Rev"
  end
end

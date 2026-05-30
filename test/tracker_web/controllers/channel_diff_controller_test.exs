defmodule TrackerWeb.ChannelDiffControllerTest do
  use TrackerWeb.ConnCase, async: true

  alias Tracker.Nixpkgs.Channel

  setup do
    Channel.create!(%{
      name: "nixos-unstable",
      display_name: "NixOS Unstable",
      status: :active,
      is_stable: true
    })

    :ok
  end

  test "redirects to the canonical diff URL when two revisions are selected", %{conn: conn} do
    conn =
      get(conn, ~p"/channels/nixos-unstable/diff", %{"compare" => ["aaa1111", "bbb2222"]})

    assert redirected_to(conn) == ~p"/channels/nixos-unstable/diff/aaa1111/bbb2222"
  end

  test "redirects back to the channel page with a flash when fewer than two are selected",
       %{conn: conn} do
    conn = get(conn, ~p"/channels/nixos-unstable/diff", %{"compare" => ["aaa1111"]})

    assert redirected_to(conn) == ~p"/channels/nixos-unstable"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "two revisions"
  end

  test "redirects back to the channel page with a flash when no compare param is sent",
       %{conn: conn} do
    conn = get(conn, ~p"/channels/nixos-unstable/diff")

    assert redirected_to(conn) == ~p"/channels/nixos-unstable"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "two revisions"
  end

  test "uses the first two compare values when more than two are selected", %{conn: conn} do
    conn =
      get(conn, ~p"/channels/nixos-unstable/diff", %{
        "compare" => ["aaa1111", "bbb2222", "ccc3333"]
      })

    assert redirected_to(conn) == ~p"/channels/nixos-unstable/diff/aaa1111/bbb2222"
  end
end

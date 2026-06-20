defmodule TrackerWeb.FeedControllerTest do
  use TrackerWeb.ConnCase, async: true

  alias Tracker.Nixpkgs.Channel

  describe "channel feed" do
    setup do
      channel =
        Channel.create!(%{
          name: "nixos-feed-test",
          display_name: "NixOS Feed Test",
          status: :active,
          is_stable: false
        })

      Ash.create!(Tracker.Nixpkgs.ChannelRevision, %{
        channel_id: channel.id,
        revision: "feed111aaa222333",
        released_at: ~U[2026-03-01 10:00:00Z]
      })

      Ash.create!(Tracker.Nixpkgs.ChannelRevision, %{
        channel_id: channel.id,
        revision: "feed222bbb333444",
        released_at: ~U[2026-03-15 10:00:00Z]
      })

      :ok
    end

    test "returns valid Atom XML", %{conn: conn} do
      conn = get(conn, "/feeds/channels/nixos-feed-test")

      assert response_content_type(conn, :xml) =~ "application/atom+xml"
      body = response(conn, 200)
      assert body =~ "<?xml"
      assert body =~ "<feed"
      assert body =~ "nixos-feed-test"
    end

    test "includes channel revisions as entries", %{conn: conn} do
      conn = get(conn, "/feeds/channels/nixos-feed-test")

      body = response(conn, 200)
      assert body =~ "feed111a"
      assert body =~ "feed222b"
    end
  end

  describe "package feed" do
    setup do
      pkg_channel =
        Channel.create!(%{
          name: "nixos-feed-pkg",
          display_name: "NixOS Feed Pkg",
          status: :active,
          is_stable: false
        })

      cr1 =
        Ash.create!(Tracker.Nixpkgs.ChannelRevision, %{
          channel_id: pkg_channel.id,
          revision: "pkgfeed111aaa222",
          released_at: ~U[2026-03-01 10:00:00Z]
        })

      cr2 =
        Ash.create!(Tracker.Nixpkgs.ChannelRevision, %{
          channel_id: pkg_channel.id,
          revision: "pkgfeed222bbb333",
          released_at: ~U[2026-03-15 10:00:00Z]
        })

      package =
        Tracker.Nixpkgs.Package
        |> Ash.Changeset.for_create(:create, %{attribute: "feed-test-pkg"})
        |> Ash.create!()

      Tracker.Fixtures.apply_package_revision!(cr1, [{package, "1.0.0"}])
      Tracker.Fixtures.apply_package_revision!(cr2, [{package, "2.0.0"}])

      :ok
    end

    test "returns valid Atom XML with version changes", %{conn: conn} do
      conn = get(conn, "/feeds/packages/feed-test-pkg")

      assert response_content_type(conn, :xml) =~ "application/atom+xml"
      body = response(conn, 200)
      assert body =~ "<?xml"
      assert body =~ "<feed"
      assert body =~ "feed-test-pkg"
      assert body =~ "1.0.0"
      assert body =~ "2.0.0"
    end

    test "filters by channel query param", %{conn: conn} do
      conn = get(conn, "/feeds/packages/feed-test-pkg?channel=nixos-feed-pkg")

      body = response(conn, 200)
      assert body =~ "nixos-feed-pkg"
      assert body =~ "1.0.0"
    end
  end
end

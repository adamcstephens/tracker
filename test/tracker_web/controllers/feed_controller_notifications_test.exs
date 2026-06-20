defmodule TrackerWeb.FeedControllerNotificationsTest do
  use TrackerWeb.ConnCase, async: true

  import Tracker.Fixtures

  alias Tracker.Accounts.User

  defp feed_token!(user) do
    {:ok, rotated} = User.rotate_feed_token(user, actor: user)
    rotated.feed_token
  end

  defp published_notification!(user, channel_name, occurred_at) do
    chan = channel!(channel_name)
    rev = channel_revision!(chan)

    notification!(user, %{
      type: :channel_revision_published,
      channel_id: chan.id,
      channel_revision_id: rev.id,
      occurred_at: occurred_at
    })
  end

  test "serves a valid token's notifications as an Atom feed", %{conn: conn} do
    user = register_user!()
    published_notification!(user, "nixos-alpha", ~U[2024-01-01 00:00:00Z])

    conn = get(conn, "/feeds/notifications/#{feed_token!(user)}")

    assert response(conn, 200)
    assert ["application/atom+xml" <> _] = get_resp_header(conn, "content-type")
    assert response(conn, 200) =~ "published on nixos-alpha"
  end

  test "renders the version bump for package_version_changed entries", %{conn: conn} do
    user = register_user!()
    pkg = package!("vim")
    chan = channel!("nixos-unstable")
    prev = channel_revision!(chan, %{released_at: ~U[2026-02-01 00:00:00Z]})

    rev =
      channel_revision!(chan, %{
        previous_channel_revision_id: prev.id,
        released_at: ~U[2026-02-02 00:00:00Z]
      })

    apply_package_revision!(prev, [{pkg, "9.0"}])
    apply_package_revision!(rev, [{pkg, "9.1"}])

    notification!(user, %{
      type: :package_version_changed,
      package_id: pkg.id,
      channel_id: chan.id,
      channel_revision_id: rev.id
    })

    body = conn |> get("/feeds/notifications/#{feed_token!(user)}") |> response(200)

    assert body =~ "vim 9.0 → 9.1 on nixos-unstable"
  end

  test "orders entries newest first", %{conn: conn} do
    user = register_user!()
    published_notification!(user, "nixos-older", ~U[2024-01-01 00:00:00Z])
    published_notification!(user, "nixos-newer", ~U[2024-06-01 00:00:00Z])

    body = conn |> get("/feeds/notifications/#{feed_token!(user)}") |> response(200)

    assert :binary.match(body, "nixos-newer") < :binary.match(body, "nixos-older")
  end

  test "rejects an invalid token with 401", %{conn: conn} do
    conn = get(conn, "/feeds/notifications/trk_feed_not-a-real-token")
    assert response(conn, 401)
  end

  test "rejects a rotated token with 401", %{conn: conn} do
    user = register_user!()
    token = feed_token!(user)
    _new = feed_token!(user)

    conn = get(conn, "/feeds/notifications/#{token}")
    assert response(conn, 401)
  end

  test "never exposes another user's notifications", %{conn: conn} do
    alice = register_user!()
    bob = register_user!()
    published_notification!(alice, "nixos-alice", ~U[2024-01-01 00:00:00Z])
    published_notification!(bob, "nixos-bob", ~U[2024-01-01 00:00:00Z])

    body = conn |> get("/feeds/notifications/#{feed_token!(alice)}") |> response(200)

    assert body =~ "nixos-alice"
    refute body =~ "nixos-bob"
  end
end

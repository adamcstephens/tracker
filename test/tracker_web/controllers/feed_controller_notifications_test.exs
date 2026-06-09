defmodule TrackerWeb.FeedControllerNotificationsTest do
  use TrackerWeb.ConnCase, async: true

  import Tracker.Fixtures

  alias TrackerWeb.FeedToken

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

    conn = get(conn, "/feeds/notifications/#{FeedToken.sign(user)}")

    assert response(conn, 200)
    assert ["application/atom+xml" <> _] = get_resp_header(conn, "content-type")
    assert response(conn, 200) =~ "New revision published on nixos-alpha"
  end

  test "orders entries newest first", %{conn: conn} do
    user = register_user!()
    published_notification!(user, "nixos-older", ~U[2024-01-01 00:00:00Z])
    published_notification!(user, "nixos-newer", ~U[2024-06-01 00:00:00Z])

    body = conn |> get("/feeds/notifications/#{FeedToken.sign(user)}") |> response(200)

    assert :binary.match(body, "nixos-newer") < :binary.match(body, "nixos-older")
  end

  test "rejects an invalid token with 401", %{conn: conn} do
    conn = get(conn, "/feeds/notifications/not-a-real-token")
    assert response(conn, 401)
  end

  test "rejects a token whose seed has been rotated with 401", %{conn: conn} do
    user = register_user!()
    token = FeedToken.sign(user)
    {:ok, _} = Tracker.Accounts.User.rotate_feed_token(user, actor: user)

    conn = get(conn, "/feeds/notifications/#{token}")
    assert response(conn, 401)
  end

  test "never exposes another user's notifications", %{conn: conn} do
    alice = register_user!()
    bob = register_user!()
    published_notification!(alice, "nixos-alice", ~U[2024-01-01 00:00:00Z])
    published_notification!(bob, "nixos-bob", ~U[2024-01-01 00:00:00Z])

    body = conn |> get("/feeds/notifications/#{FeedToken.sign(alice)}") |> response(200)

    assert body =~ "nixos-alice"
    refute body =~ "nixos-bob"
  end
end

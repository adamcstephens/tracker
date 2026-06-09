defmodule TrackerWeb.FeedTokenTest do
  use Tracker.DataCase, async: true

  import Tracker.Fixtures

  alias Tracker.Accounts.User
  alias TrackerWeb.FeedToken

  test "round-trips a signed token back to its user" do
    user = register_user!()
    token = FeedToken.sign(user)

    assert {:ok, %User{id: id}} = FeedToken.verify(token)
    assert id == user.id
  end

  test "rotating the seed invalidates a previously signed token" do
    user = register_user!()
    token = FeedToken.sign(user)
    {:ok, _rotated} = User.rotate_feed_token(user, actor: user)

    assert {:error, :stale_token} = FeedToken.verify(token)
  end

  test "a token signed after rotation verifies" do
    user = register_user!()
    {:ok, rotated} = User.rotate_feed_token(user, actor: user)

    token = FeedToken.sign(rotated)
    assert {:ok, %User{id: id}} = FeedToken.verify(token)
    assert id == user.id
  end

  test "rejects a tampered token" do
    user = register_user!()
    token = FeedToken.sign(user)

    assert {:error, _} = FeedToken.verify(token <> "x")
  end

  test "rejects a non-token value" do
    assert {:error, _} = FeedToken.verify("not-a-token")
  end
end

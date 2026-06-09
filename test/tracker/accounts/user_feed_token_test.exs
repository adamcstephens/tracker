defmodule Tracker.Accounts.UserFeedTokenTest do
  use Tracker.DataCase, async: true

  import Tracker.Fixtures

  alias Tracker.Accounts.User

  describe "rotate_feed_token" do
    test "mints a prefixed token" do
      user = register_user!()
      assert is_nil(user.feed_token)

      assert {:ok, rotated} = User.rotate_feed_token(user, actor: user)
      assert String.starts_with?(rotated.feed_token, "trk_feed_")
    end

    test "produces a different token each time" do
      user = register_user!()
      {:ok, once} = User.rotate_feed_token(user, actor: user)
      {:ok, twice} = User.rotate_feed_token(once, actor: user)

      refute once.feed_token == twice.feed_token
    end

    test "another user cannot rotate it" do
      user = register_user!()
      other = register_user!()

      assert {:error, _} = User.rotate_feed_token(user, actor: other)
    end
  end

  describe "by_feed_token" do
    test "resolves the owning user" do
      user = register_user!()
      {:ok, rotated} = User.rotate_feed_token(user, actor: user)

      assert {:ok, %User{id: id}} = User.by_feed_token(rotated.feed_token, authorize?: false)
      assert id == user.id
    end

    test "returns nil for an unknown token" do
      assert {:ok, nil} = User.by_feed_token("trk_feed_nope", authorize?: false)
    end

    test "a rotated token no longer resolves" do
      user = register_user!()
      {:ok, first} = User.rotate_feed_token(user, actor: user)
      {:ok, _second} = User.rotate_feed_token(first, actor: user)

      assert {:ok, nil} = User.by_feed_token(first.feed_token, authorize?: false)
    end
  end
end

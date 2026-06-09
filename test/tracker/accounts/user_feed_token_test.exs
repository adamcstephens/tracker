defmodule Tracker.Accounts.UserFeedTokenTest do
  use Tracker.DataCase, async: true

  import Tracker.Fixtures

  alias Tracker.Accounts.User

  describe "rotate_feed_token" do
    test "sets a fresh seed" do
      user = register_user!()
      assert is_nil(user.feed_token_seed)

      assert {:ok, rotated} = User.rotate_feed_token(user, actor: user)
      refute is_nil(rotated.feed_token_seed)
    end

    test "produces a different seed each time" do
      user = register_user!()
      {:ok, once} = User.rotate_feed_token(user, actor: user)
      {:ok, twice} = User.rotate_feed_token(once, actor: user)

      refute once.feed_token_seed == twice.feed_token_seed
    end

    test "another user cannot rotate it" do
      user = register_user!()
      other = register_user!()

      assert {:error, _} = User.rotate_feed_token(user, actor: other)
    end
  end
end

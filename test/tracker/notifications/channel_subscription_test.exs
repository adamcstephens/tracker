defmodule Tracker.Notifications.ChannelSubscriptionTest do
  use Tracker.DataCase, async: true

  import Tracker.Fixtures

  alias Tracker.Notifications.ChannelSubscription

  describe "subscribe" do
    test "subscribes the actor to a channel" do
      user = register_user!()
      chan = channel!()

      assert {:ok, sub} = ChannelSubscription.subscribe(chan.id, actor: user)
      assert sub.user_id == user.id
      assert sub.channel_id == chan.id
    end

    test "is idempotent" do
      user = register_user!()
      chan = channel!()

      assert {:ok, _} = ChannelSubscription.subscribe(chan.id, actor: user)
      assert {:ok, _} = ChannelSubscription.subscribe(chan.id, actor: user)

      assert [_only] = ChannelSubscription.for_user!(actor: user)
    end

    test "requires an actor" do
      chan = channel!()

      assert {:error, _} = ChannelSubscription.subscribe(chan.id, actor: nil)
    end
  end

  describe "find" do
    test "returns the actor's subscription, or nil" do
      user = register_user!()
      chan = channel!()

      assert {:ok, nil} = ChannelSubscription.find(chan.id, actor: user)

      {:ok, sub} = ChannelSubscription.subscribe(chan.id, actor: user)

      assert {:ok, found} = ChannelSubscription.find(chan.id, actor: user)
      assert found.id == sub.id
    end

    test "does not find another user's subscription" do
      alice = register_user!()
      bob = register_user!()
      chan = channel!()
      {:ok, _} = ChannelSubscription.subscribe(chan.id, actor: alice)

      assert {:ok, nil} = ChannelSubscription.find(chan.id, actor: bob)
    end
  end

  describe "destroy" do
    test "removes the subscription" do
      user = register_user!()
      chan = channel!()
      {:ok, sub} = ChannelSubscription.subscribe(chan.id, actor: user)

      assert :ok = ChannelSubscription.destroy(sub, actor: user)
      assert {:ok, nil} = ChannelSubscription.find(chan.id, actor: user)
    end

    test "another user cannot destroy it" do
      alice = register_user!()
      bob = register_user!()
      chan = channel!()
      {:ok, sub} = ChannelSubscription.subscribe(chan.id, actor: alice)

      assert {:error, _} = ChannelSubscription.destroy(sub, actor: bob)
      assert {:ok, %ChannelSubscription{}} = ChannelSubscription.find(chan.id, actor: alice)
    end
  end

  describe "for_user" do
    test "lists only the actor's own subscriptions" do
      alice = register_user!()
      bob = register_user!()
      chan = channel!()

      {:ok, _} = ChannelSubscription.subscribe(chan.id, actor: alice)

      assert [_] = ChannelSubscription.for_user!(actor: alice)
      assert [] = ChannelSubscription.for_user!(actor: bob)
    end
  end
end

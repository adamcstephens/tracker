defmodule Tracker.Notifications.ChangeSubscriptionTest do
  use Tracker.DataCase, async: true

  import Tracker.Fixtures

  alias Tracker.Notifications.ChangeSubscription

  describe "subscribe" do
    test "subscribes the actor to a change scoped to a channel" do
      user = register_user!()
      change = change!()
      chan = channel!()

      assert {:ok, sub} = ChangeSubscription.subscribe(change.id, chan.id, actor: user)
      assert sub.user_id == user.id
      assert sub.change_id == change.id
      assert sub.channel_id == chan.id
    end

    test "subscribes to any branch when the channel is nil" do
      user = register_user!()
      change = change!()

      assert {:ok, sub} = ChangeSubscription.subscribe(change.id, nil, actor: user)
      assert sub.channel_id == nil
    end

    test "is idempotent for the same scope" do
      user = register_user!()
      change = change!()
      chan = channel!()

      assert {:ok, _} = ChangeSubscription.subscribe(change.id, chan.id, actor: user)
      assert {:ok, _} = ChangeSubscription.subscribe(change.id, chan.id, actor: user)

      assert [_only] = ChangeSubscription.for_user!(actor: user)
    end

    test "any-branch and specific-channel are distinct subscriptions" do
      user = register_user!()
      change = change!()
      chan = channel!()

      {:ok, _} = ChangeSubscription.subscribe(change.id, nil, actor: user)
      {:ok, _} = ChangeSubscription.subscribe(change.id, chan.id, actor: user)

      assert length(ChangeSubscription.for_user!(actor: user)) == 2
    end

    test "requires an actor" do
      change = change!()

      assert {:error, _} = ChangeSubscription.subscribe(change.id, nil, actor: nil)
    end
  end

  describe "find" do
    test "returns the actor's subscription at the matching scope" do
      user = register_user!()
      change = change!()
      chan = channel!()
      {:ok, sub} = ChangeSubscription.subscribe(change.id, chan.id, actor: user)

      assert {:ok, found} = ChangeSubscription.find(change.id, chan.id, actor: user)
      assert found.id == sub.id
    end

    test "distinguishes the any-branch scope from a specific channel" do
      user = register_user!()
      change = change!()
      chan = channel!()
      {:ok, any} = ChangeSubscription.subscribe(change.id, nil, actor: user)

      assert {:ok, found} = ChangeSubscription.find(change.id, nil, actor: user)
      assert found.id == any.id
      assert {:ok, nil} = ChangeSubscription.find(change.id, chan.id, actor: user)
    end

    test "does not find another user's subscription" do
      alice = register_user!()
      bob = register_user!()
      change = change!()
      {:ok, _} = ChangeSubscription.subscribe(change.id, nil, actor: alice)

      assert {:ok, nil} = ChangeSubscription.find(change.id, nil, actor: bob)
    end
  end

  describe "destroy" do
    test "removes the subscription" do
      user = register_user!()
      change = change!()
      {:ok, sub} = ChangeSubscription.subscribe(change.id, nil, actor: user)

      assert :ok = ChangeSubscription.destroy(sub, actor: user)
      assert {:ok, nil} = ChangeSubscription.find(change.id, nil, actor: user)
    end

    test "another user cannot destroy it" do
      alice = register_user!()
      bob = register_user!()
      change = change!()
      {:ok, sub} = ChangeSubscription.subscribe(change.id, nil, actor: alice)

      assert {:error, _} = ChangeSubscription.destroy(sub, actor: bob)
      assert {:ok, %ChangeSubscription{}} = ChangeSubscription.find(change.id, nil, actor: alice)
    end
  end

  describe "for_user" do
    test "lists only the actor's own subscriptions" do
      alice = register_user!()
      bob = register_user!()
      change = change!()

      {:ok, _} = ChangeSubscription.subscribe(change.id, nil, actor: alice)

      assert [_] = ChangeSubscription.for_user!(actor: alice)
      assert [] = ChangeSubscription.for_user!(actor: bob)
    end
  end
end

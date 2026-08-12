defmodule Tracker.Notifications.PackageSubscriptionTest do
  use Tracker.DataCase, async: true

  import Tracker.Fixtures

  alias Tracker.Notifications.PackageSubscription

  describe "subscribe" do
    test "subscribes the actor to a package scoped to a channel" do
      user = register_user!()
      pkg = package!()
      chan = channel!()

      assert {:ok, sub} = PackageSubscription.subscribe(pkg.id, chan.id, actor: user)
      assert sub.user_id == user.id
      assert sub.package_id == pkg.id
      assert sub.channel_id == chan.id
    end

    test "subscribes to all channels when the channel is nil" do
      user = register_user!()
      pkg = package!()

      assert {:ok, sub} = PackageSubscription.subscribe(pkg.id, nil, actor: user)
      assert sub.channel_id == nil
    end

    test "is idempotent for the same scope" do
      user = register_user!()
      pkg = package!()
      chan = channel!()

      assert {:ok, _} = PackageSubscription.subscribe(pkg.id, chan.id, actor: user)
      assert {:ok, _} = PackageSubscription.subscribe(pkg.id, chan.id, actor: user)

      assert [_only] = PackageSubscription.for_user!(actor: user)
    end

    test "all-channels and specific-channel are distinct subscriptions" do
      user = register_user!()
      pkg = package!()
      chan = channel!()

      {:ok, _} = PackageSubscription.subscribe(pkg.id, nil, actor: user)
      {:ok, _} = PackageSubscription.subscribe(pkg.id, chan.id, actor: user)

      assert length(PackageSubscription.for_user!(actor: user)) == 2
    end

    test "requires an actor" do
      pkg = package!()

      assert {:error, _} = PackageSubscription.subscribe(pkg.id, nil, actor: nil)
    end
  end

  describe "events" do
    test "defaults to the revision events" do
      user = register_user!()
      pkg = package!()

      {:ok, sub} = PackageSubscription.subscribe(pkg.id, nil, actor: user)

      assert sub.events == [:package_version_changed, :package_added, :package_removed]
    end

    test "set_events replaces the selection" do
      user = register_user!()
      pkg = package!()
      {:ok, sub} = PackageSubscription.subscribe(pkg.id, nil, actor: user)

      assert {:ok, updated} =
               PackageSubscription.set_events(sub, [:package_change_merged], actor: user)

      assert updated.events == [:package_change_merged]
    end

    test "rejects an unknown event" do
      user = register_user!()
      pkg = package!()
      {:ok, sub} = PackageSubscription.subscribe(pkg.id, nil, actor: user)

      assert {:error, _} = PackageSubscription.set_events(sub, [:package_exploded], actor: user)
    end

    test "rejects an empty selection" do
      user = register_user!()
      pkg = package!()
      {:ok, sub} = PackageSubscription.subscribe(pkg.id, nil, actor: user)

      assert {:error, _} = PackageSubscription.set_events(sub, [], actor: user)
    end

    test "another user cannot set the events" do
      alice = register_user!()
      bob = register_user!()
      pkg = package!()
      {:ok, sub} = PackageSubscription.subscribe(pkg.id, nil, actor: alice)

      assert {:error, _} = PackageSubscription.set_events(sub, [:package_added], actor: bob)
    end

    test "re-subscribing preserves an existing selection" do
      user = register_user!()
      pkg = package!()
      {:ok, sub} = PackageSubscription.subscribe(pkg.id, nil, actor: user)
      {:ok, _} = PackageSubscription.set_events(sub, [:package_change_opened], actor: user)

      {:ok, resubscribed} = PackageSubscription.subscribe(pkg.id, nil, actor: user)

      assert resubscribed.events == [:package_change_opened]
    end
  end

  describe "find" do
    test "returns the actor's subscription at the matching scope" do
      user = register_user!()
      pkg = package!()
      chan = channel!()
      {:ok, sub} = PackageSubscription.subscribe(pkg.id, chan.id, actor: user)

      assert {:ok, found} = PackageSubscription.find(pkg.id, chan.id, actor: user)
      assert found.id == sub.id
    end

    test "distinguishes the all-channels scope from a specific channel" do
      user = register_user!()
      pkg = package!()
      chan = channel!()
      {:ok, all} = PackageSubscription.subscribe(pkg.id, nil, actor: user)

      assert {:ok, found} = PackageSubscription.find(pkg.id, nil, actor: user)
      assert found.id == all.id
      assert {:ok, nil} = PackageSubscription.find(pkg.id, chan.id, actor: user)
    end

    test "returns nil when there is no subscription" do
      user = register_user!()
      pkg = package!()

      assert {:ok, nil} = PackageSubscription.find(pkg.id, nil, actor: user)
    end

    test "does not find another user's subscription" do
      alice = register_user!()
      bob = register_user!()
      pkg = package!()
      {:ok, _} = PackageSubscription.subscribe(pkg.id, nil, actor: alice)

      assert {:ok, nil} = PackageSubscription.find(pkg.id, nil, actor: bob)
    end
  end

  describe "destroy" do
    test "removes the subscription" do
      user = register_user!()
      pkg = package!()
      {:ok, sub} = PackageSubscription.subscribe(pkg.id, nil, actor: user)

      assert :ok = PackageSubscription.destroy(sub, actor: user)
      assert {:ok, nil} = PackageSubscription.find(pkg.id, nil, actor: user)
    end

    test "another user cannot destroy it" do
      alice = register_user!()
      bob = register_user!()
      pkg = package!()
      {:ok, sub} = PackageSubscription.subscribe(pkg.id, nil, actor: alice)

      assert {:error, _} = PackageSubscription.destroy(sub, actor: bob)
      assert {:ok, %PackageSubscription{}} = PackageSubscription.find(pkg.id, nil, actor: alice)
    end
  end

  describe "for_user" do
    test "lists only the actor's own subscriptions" do
      alice = register_user!()
      bob = register_user!()
      pkg = package!()

      {:ok, _} = PackageSubscription.subscribe(pkg.id, nil, actor: alice)

      assert [_] = PackageSubscription.for_user!(actor: alice)
      assert [] = PackageSubscription.for_user!(actor: bob)
    end
  end
end

defmodule Tracker.Notifications.ChangeSubscriptionTest do
  use Tracker.DataCase, async: true

  import Tracker.Fixtures

  alias Tracker.Accounts.User
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

  describe "auto_subscribe_author" do
    test "subscribes an opted-in author at the any-branch scope" do
      user = register_user!(%{"id" => 7001})
      User.set_auto_subscribe!(user, %{auto_subscribe_authored_changes: true}, actor: user)
      change = change!()

      assert :ok = ChangeSubscription.auto_subscribe_author(change.id, 7001)

      assert [%{change_id: change_id, channel_id: nil}] =
               ChangeSubscription.for_user!(actor: user)

      assert change_id == change.id
    end

    test "does nothing when the author has not opted in" do
      user = register_user!(%{"id" => 7002})
      change = change!()

      assert :ok = ChangeSubscription.auto_subscribe_author(change.id, 7002)

      assert [] = ChangeSubscription.for_user!(actor: user)
    end

    test "does nothing when the author github id is nil or unknown" do
      change = change!()

      assert :ok = ChangeSubscription.auto_subscribe_author(change.id, nil)
      assert :ok = ChangeSubscription.auto_subscribe_author(change.id, 404_404)
    end

    test "leaves an existing manual subscription intact" do
      user = register_user!(%{"id" => 7003})
      User.set_auto_subscribe!(user, %{auto_subscribe_authored_changes: true}, actor: user)
      change = change!()
      chan = channel!()
      {:ok, manual} = ChangeSubscription.subscribe(change.id, chan.id, actor: user)

      assert :ok = ChangeSubscription.auto_subscribe_author(change.id, 7003)

      subs = ChangeSubscription.for_user!(actor: user)
      assert length(subs) == 2
      assert manual.id in Enum.map(subs, & &1.id)
    end
  end

  describe "auto_subscribe_merger" do
    test "subscribes an opted-in merger at the any-branch scope" do
      user = register_user!(%{"id" => 7101})
      User.set_auto_subscribe!(user, %{auto_subscribe_merged_changes: true}, actor: user)
      change = change!()

      assert :ok = ChangeSubscription.auto_subscribe_merger(change.id, 7101)

      assert [%{channel_id: nil}] = ChangeSubscription.for_user!(actor: user)
    end

    test "the authored preference alone does not subscribe the merger" do
      user = register_user!(%{"id" => 7102})
      User.set_auto_subscribe!(user, %{auto_subscribe_authored_changes: true}, actor: user)
      change = change!()

      assert :ok = ChangeSubscription.auto_subscribe_merger(change.id, 7102)

      assert [] = ChangeSubscription.for_user!(actor: user)
    end

    test "authoring and merging the same change yields a single subscription" do
      user = register_user!(%{"id" => 7103})

      User.set_auto_subscribe!(
        user,
        %{auto_subscribe_authored_changes: true, auto_subscribe_merged_changes: true},
        actor: user
      )

      change = change!()

      assert :ok = ChangeSubscription.auto_subscribe_author(change.id, 7103)
      assert :ok = ChangeSubscription.auto_subscribe_merger(change.id, 7103)

      assert [_only] = ChangeSubscription.for_user!(actor: user)
    end
  end
end

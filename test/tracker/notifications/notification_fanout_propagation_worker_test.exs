defmodule Tracker.Notifications.NotificationFanoutPropagationWorkerTest do
  use Tracker.DataCase, async: true

  import Tracker.Fixtures

  alias Tracker.Notifications.{ChangeSubscription, Notification}
  alias Tracker.Notifications.NotificationFanoutPropagationWorker, as: Worker

  test "suppresses old branch propagation but allows a recent channel arrival" do
    user = register_user!()
    old = DateTime.add(DateTime.utc_now(:second), -31, :day)
    change = change!(nil, %{merged_at: old})
    {:ok, _} = ChangeSubscription.subscribe(change.id, nil, actor: user)
    branch = change_branch!(change, "master")

    assert :ok = Worker.run(change_branch_id: branch.id)
    assert [] = Notification.for_user!(actor: user)

    revision = channel_revision!()
    channel_branch = change_branch!(change, "nixos-unstable", revision)
    assert :ok = Worker.run(change_branch_id: channel_branch.id)
    assert [%{change_branch_id: id}] = Notification.for_user!(actor: user)
    assert id == channel_branch.id
  end

  test "suppresses a historical channel arrival for a channel subscriber" do
    user = register_user!()
    change = change!(nil, %{merged_at: DateTime.utc_now(:second)})
    channel = channel!()
    old = DateTime.add(DateTime.utc_now(:second), -31, :day)
    revision = channel_revision!(channel, %{released_at: old})
    {:ok, _} = ChangeSubscription.subscribe(change.id, channel.id, actor: user)
    branch = change_branch!(change, "nixos-unstable", revision)

    assert :ok = Worker.run(change_branch_id: branch.id)
    assert :ok = Worker.run(change_branch_id: branch.id)
    assert [] = Notification.for_user!(actor: user)
  end

  describe "any-branch subscriptions" do
    test "notifies a nil-channel change subscriber on propagation" do
      user = register_user!()
      change = change!(nil, %{merged_at: DateTime.utc_now(:second)})
      {:ok, _} = ChangeSubscription.subscribe(change.id, nil, actor: user)
      branch = change_branch!(change, "staging-next")

      assert :ok = Worker.run(change_branch_id: branch.id)

      assert [n] = Notification.for_user!(actor: user)
      assert n.type == :change_propagated
      assert n.change_id == change.id
      assert n.change_branch_id == branch.id
    end
  end

  describe "channel-targeted subscriptions" do
    test "notifies when the branch maps to the subscribed channel" do
      user = register_user!()
      change = change!()
      chan = channel!()
      rev = channel_revision!(chan)
      {:ok, _} = ChangeSubscription.subscribe(change.id, chan.id, actor: user)
      branch = change_branch!(change, "nixos-unstable", rev)

      assert :ok = Worker.run(change_branch_id: branch.id)

      assert [n] = Notification.for_user!(actor: user)
      assert n.type == :change_propagated
      assert n.channel_id == chan.id
    end

    test "does not notify when the branch maps to a different channel" do
      user = register_user!()
      change = change!()
      subscribed = channel!()
      other = channel!()
      rev = channel_revision!(other)
      {:ok, _} = ChangeSubscription.subscribe(change.id, subscribed.id, actor: user)
      branch = change_branch!(change, "nixos-unstable", rev)

      assert :ok = Worker.run(change_branch_id: branch.id)
      assert [] = Notification.for_user!(actor: user)
    end

    test "does not notify a channel-targeted subscriber on an unlinked branch" do
      user = register_user!()
      change = change!()
      chan = channel!()
      {:ok, _} = ChangeSubscription.subscribe(change.id, chan.id, actor: user)
      branch = change_branch!(change, "staging-next")

      assert :ok = Worker.run(change_branch_id: branch.id)
      assert [] = Notification.for_user!(actor: user)
    end
  end

  describe "idempotency" do
    test "re-running produces no duplicate notifications" do
      user = register_user!()
      change = change!(nil, %{merged_at: DateTime.utc_now(:second)})
      {:ok, _} = ChangeSubscription.subscribe(change.id, nil, actor: user)
      branch = change_branch!(change, "staging-next")

      assert :ok = Worker.run(change_branch_id: branch.id)
      assert :ok = Worker.run(change_branch_id: branch.id)

      assert [_only] = Notification.for_user!(actor: user)
    end
  end

  describe "ChangeBranch.create enqueues the worker" do
    test "on creation" do
      change = change!()
      branch = change_branch!(change, "staging-next")

      assert_enqueued(worker: Worker, args: %{change_branch_id: branch.id})
    end
  end
end

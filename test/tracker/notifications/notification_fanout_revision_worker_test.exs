defmodule Tracker.Notifications.NotificationFanoutRevisionWorkerTest do
  use Tracker.DataCase, async: true

  import Tracker.Fixtures

  alias Tracker.Notifications.{ChannelSubscription, Notification, PackageSubscription}
  alias Tracker.Notifications.NotificationFanoutRevisionWorker, as: Worker

  defp channel_with_revisions do
    chan = channel!()
    prev = channel_revision!(chan, %{released_at: ~U[2026-01-01 00:00:00Z]})

    rev =
      channel_revision!(chan, %{
        previous_channel_revision_id: prev.id,
        released_at: ~U[2026-01-02 00:00:00Z]
      })

    {chan, prev, rev}
  end

  defp types_for(user) do
    Notification.for_user!(actor: user) |> Enum.map(& &1.type)
  end

  describe "channel subscriptions" do
    test "notifies channel subscribers of a published revision" do
      user = register_user!()
      {chan, _prev, rev} = channel_with_revisions()
      {:ok, _} = ChannelSubscription.subscribe(chan.id, actor: user)

      assert :ok = Worker.run(channel_revision_id: rev.id)

      assert [n] = Notification.for_user!(actor: user)
      assert n.type == :channel_revision_published
      assert n.channel_id == chan.id
      assert n.channel_revision_id == rev.id
    end

    test "does not notify subscribers of a different channel" do
      user = register_user!()
      {_chan, _prev, rev} = channel_with_revisions()
      {:ok, _} = ChannelSubscription.subscribe(channel!().id, actor: user)

      assert :ok = Worker.run(channel_revision_id: rev.id)
      assert [] = Notification.for_user!(actor: user)
    end
  end

  describe "package subscriptions" do
    test "notifies on a version change" do
      user = register_user!()
      {_chan, prev, rev} = channel_with_revisions()
      pkg = package!()
      apply_package_revision!(prev, [{pkg, "1.0"}])
      apply_package_revision!(rev, [{pkg, "2.0"}])
      {:ok, _} = PackageSubscription.subscribe(pkg.id, nil, actor: user)

      assert :ok = Worker.run(channel_revision_id: rev.id)

      assert [n] = Notification.for_user!(actor: user)
      assert n.type == :package_version_changed
      assert n.package_id == pkg.id
    end

    test "does not notify when the version is unchanged" do
      user = register_user!()
      {_chan, prev, rev} = channel_with_revisions()
      pkg = package!()
      apply_package_revision!(prev, [{pkg, "1.0"}])
      apply_package_revision!(rev, [{pkg, "1.0"}])
      {:ok, _} = PackageSubscription.subscribe(pkg.id, nil, actor: user)

      assert :ok = Worker.run(channel_revision_id: rev.id)
      assert [] = Notification.for_user!(actor: user)
    end

    test "notifies on an added package" do
      user = register_user!()
      {_chan, _prev, rev} = channel_with_revisions()
      pkg = package!()
      # present at rev but not at prev → added
      apply_package_revision!(rev, [{pkg, "1.0"}])
      {:ok, _} = PackageSubscription.subscribe(pkg.id, nil, actor: user)

      assert :ok = Worker.run(channel_revision_id: rev.id)
      assert [:package_added] = types_for(user)
    end

    test "notifies on a removed package" do
      user = register_user!()
      {_chan, prev, rev} = channel_with_revisions()
      pkg = package!()
      # present at prev, removed at rev
      apply_package_revision!(prev, [{pkg, "1.0"}])
      remove_package!(rev, pkg)
      {:ok, _} = PackageSubscription.subscribe(pkg.id, nil, actor: user)

      assert :ok = Worker.run(channel_revision_id: rev.id)
      assert [:package_removed] = types_for(user)
    end

    test "respects a channel-scoped subscription" do
      user = register_user!()
      {chan, prev, rev} = channel_with_revisions()
      pkg = package!()
      apply_package_revision!(prev, [{pkg, "1.0"}])
      apply_package_revision!(rev, [{pkg, "2.0"}])
      # subscribed to a *different* channel: no notification
      {:ok, _} = PackageSubscription.subscribe(pkg.id, channel!().id, actor: user)

      assert :ok = Worker.run(channel_revision_id: rev.id)
      assert [] = Notification.for_user!(actor: user)

      # subscribed to this channel: notified
      {:ok, _} = PackageSubscription.subscribe(pkg.id, chan.id, actor: user)
      assert :ok = Worker.run(channel_revision_id: rev.id)
      assert [:package_version_changed] = types_for(user)
    end

    test "skips package fan-out on a channel's first revision" do
      user = register_user!()
      chan = channel!()
      rev = channel_revision!(chan)
      pkg = package!()
      apply_package_revision!(rev, [{pkg, "1.0"}])
      {:ok, _} = PackageSubscription.subscribe(pkg.id, nil, actor: user)

      assert :ok = Worker.run(channel_revision_id: rev.id)
      assert [] = Notification.for_user!(actor: user)
    end
  end

  describe "idempotency" do
    test "re-running produces no duplicate notifications" do
      user = register_user!()
      {chan, prev, rev} = channel_with_revisions()
      pkg = package!()
      apply_package_revision!(prev, [{pkg, "1.0"}])
      apply_package_revision!(rev, [{pkg, "2.0"}])
      {:ok, _} = ChannelSubscription.subscribe(chan.id, actor: user)
      {:ok, _} = PackageSubscription.subscribe(pkg.id, nil, actor: user)

      assert :ok = Worker.run(channel_revision_id: rev.id)
      assert :ok = Worker.run(channel_revision_id: rev.id)
      assert :ok = Worker.run(channel_revision_id: rev.id)

      assert length(Notification.for_user!(actor: user)) == 2
    end
  end

  describe "record_result enqueues the worker" do
    test "on a successful result" do
      {_chan, _prev, rev} = channel_with_revisions()
      Tracker.Nixpkgs.ChannelRevision.record_result!(rev, %{result: :success})

      assert_enqueued(worker: Worker, args: %{channel_revision_id: rev.id})
    end

    test "not on a non-successful result" do
      {_chan, _prev, rev} = channel_with_revisions()
      Tracker.Nixpkgs.ChannelRevision.record_result!(rev, %{result: :error})

      refute_enqueued(worker: Worker)
    end
  end
end

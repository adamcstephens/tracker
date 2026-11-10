defmodule Tracker.Notifications.InboxPrunerWorkerTest do
  use Tracker.DataCase, async: true

  import Tracker.Fixtures

  alias Tracker.Notifications.{InboxPrunerWorker, Notification}

  test "deletes only notifications older than 180 days across users and states" do
    now = ~U[2026-11-10 00:00:00Z]
    cutoff = DateTime.add(now, -180, :day)
    alice = register_user!()
    bob = register_user!()

    for {user, key, occurred_at} <- [
          {alice, "old-unread", DateTime.add(cutoff, -1, :second)},
          {alice, "old-saved-read", DateTime.add(cutoff, -1, :day)},
          {bob, "old-other-user", DateTime.add(cutoff, -1, :second)},
          {alice, "boundary", cutoff},
          {alice, "recent", now}
        ] do
      :ok =
        Notification.fanout([
          %{
            user_id: user.id,
            type: :channel_revision_published,
            occurred_at: occurred_at,
            dedup_key: key
          }
        ])
    end

    saved = Enum.find(Notification.for_user!(actor: alice), &(&1.dedup_key == "old-saved-read"))
    saved |> Notification.save!(actor: alice) |> Notification.mark_read!(actor: alice)

    assert :ok = InboxPrunerWorker.run(now)

    assert Enum.map(Notification.for_user!(actor: alice), & &1.dedup_key) == [
             "recent",
             "boundary"
           ]

    assert [] = Notification.for_user!(actor: bob)
    assert :ok = InboxPrunerWorker.run(now)
  end

  test "runs as an Oban job with an empty inbox" do
    assert :ok = InboxPrunerWorker.perform(%Oban.Job{})
  end

  test "is scheduled daily at midnight UTC" do
    plugins = Application.fetch_env!(:tracker, Oban)[:plugins]
    cron = Keyword.fetch!(plugins, Oban.Plugins.Cron)
    assert {"0 0 * * *", InboxPrunerWorker} in cron[:crontab]
  end
end

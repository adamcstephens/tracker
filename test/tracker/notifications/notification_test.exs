defmodule Tracker.Notifications.NotificationTest do
  use Tracker.DataCase, async: true

  import Tracker.Fixtures

  alias Tracker.Notifications.Notification

  defp row(user, overrides) do
    Map.merge(
      %{
        user_id: user.id,
        type: :channel_revision_published,
        occurred_at: DateTime.utc_now(:second),
        dedup_key: "dk-#{System.unique_integer([:positive])}"
      },
      overrides
    )
  end

  describe "fanout/1" do
    test "records a batch of notifications" do
      user = register_user!()

      assert :ok = Notification.fanout([row(user, %{}), row(user, %{type: :package_added})])

      assert [_, _] = Notification.for_user!(actor: user)
    end

    test "is a no-op on an empty list" do
      assert :ok = Notification.fanout([])
    end

    test "is idempotent on dedup_key (re-run = no-op)" do
      user = register_user!()
      rows = [row(user, %{dedup_key: "stable"})]

      assert :ok = Notification.fanout(rows)
      assert :ok = Notification.fanout(rows)
      assert :ok = Notification.fanout(rows)

      assert [_only] = Notification.for_user!(actor: user)
    end

    test "preserves read_at across a re-run" do
      user = register_user!()
      rows = [row(user, %{dedup_key: "stable"})]
      :ok = Notification.fanout(rows)
      [n] = Notification.for_user!(actor: user)
      {:ok, _} = Notification.mark_read(n, actor: user)

      :ok = Notification.fanout(rows)

      assert [%Notification{read_at: read_at}] = Notification.for_user!(actor: user)
      refute is_nil(read_at)
    end
  end

  describe "for_user/1" do
    test "returns the actor's notifications newest first" do
      user = register_user!()

      :ok =
        Notification.fanout([
          row(user, %{occurred_at: ~U[2024-01-01 00:00:00Z]}),
          row(user, %{occurred_at: ~U[2024-03-01 00:00:00Z]}),
          row(user, %{occurred_at: ~U[2024-02-01 00:00:00Z]})
        ])

      occurred = Notification.for_user!(actor: user) |> Enum.map(& &1.occurred_at)
      assert occurred == Enum.sort(occurred, {:desc, DateTime})
    end

    test "does not return another user's notifications" do
      alice = register_user!()
      bob = register_user!()
      :ok = Notification.fanout([row(alice, %{})])

      assert [] = Notification.for_user!(actor: bob)
    end

    test "filters to a single channel revision when given" do
      user = register_user!()
      chan = channel!()
      rev = channel_revision!(chan)
      other = channel_revision!(chan)

      :ok =
        Notification.fanout([
          row(user, %{channel_revision_id: rev.id}),
          row(user, %{channel_revision_id: other.id})
        ])

      assert [%Notification{channel_revision_id: id}] =
               Notification.for_user!(%{channel_revision_id: rev.id}, actor: user)

      assert id == rev.id
    end
  end

  describe "mark_read/2" do
    test "sets read_at" do
      user = register_user!()
      :ok = Notification.fanout([row(user, %{})])
      [n] = Notification.for_user!(actor: user)
      assert is_nil(n.read_at)

      assert {:ok, %Notification{read_at: read_at}} = Notification.mark_read(n, actor: user)
      refute is_nil(read_at)
    end

    test "another user cannot mark it read" do
      alice = register_user!()
      bob = register_user!()
      :ok = Notification.fanout([row(alice, %{})])
      [n] = Notification.for_user!(actor: alice)

      assert {:error, _} = Notification.mark_read(n, actor: bob)
    end
  end

  describe "mark_unread/2" do
    test "clears read_at" do
      user = register_user!()
      :ok = Notification.fanout([row(user, %{})])
      [n] = Notification.for_user!(actor: user)
      {:ok, n} = Notification.mark_read(n, actor: user)
      refute is_nil(n.read_at)

      assert {:ok, %Notification{read_at: nil}} = Notification.mark_unread(n, actor: user)
    end

    test "another user cannot mark it unread" do
      alice = register_user!()
      bob = register_user!()
      :ok = Notification.fanout([row(alice, %{})])
      [n] = Notification.for_user!(actor: alice)
      {:ok, n} = Notification.mark_read(n, actor: alice)

      assert {:error, _} = Notification.mark_unread(n, actor: bob)
    end
  end
end

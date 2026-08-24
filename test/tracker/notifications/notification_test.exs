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

    test "paginates by offset with a count" do
      user = register_user!()

      :ok =
        Notification.fanout([
          row(user, %{occurred_at: ~U[2024-01-01 00:00:00Z]}),
          row(user, %{occurred_at: ~U[2024-02-01 00:00:00Z]}),
          row(user, %{occurred_at: ~U[2024-03-01 00:00:00Z]})
        ])

      assert %Ash.Page.Offset{count: 3, more?: true, results: [first, second]} =
               Notification.for_user!(%{}, page: [limit: 2, offset: 0, count: true], actor: user)

      assert first.occurred_at == ~U[2024-03-01 00:00:00Z]
      assert second.occurred_at == ~U[2024-02-01 00:00:00Z]

      assert %Ash.Page.Offset{count: 3, more?: false, results: [third]} =
               Notification.for_user!(%{}, page: [limit: 2, offset: 2, count: true], actor: user)

      assert third.occurred_at == ~U[2024-01-01 00:00:00Z]
    end

    test "orders ties by id so pages never repeat or skip a row" do
      user = register_user!()
      at = ~U[2024-01-01 00:00:00Z]

      :ok =
        Notification.fanout([
          row(user, %{occurred_at: at}),
          row(user, %{occurred_at: at}),
          row(user, %{occurred_at: at})
        ])

      paged =
        Enum.flat_map(0..2, fn offset ->
          Notification.for_user!(%{}, page: [limit: 1, offset: offset], actor: user).results
        end)

      assert length(Enum.uniq_by(paged, & &1.id)) == 3
    end

    test "filters to unread only" do
      user = register_user!()
      :ok = Notification.fanout([row(user, %{}), row(user, %{})])
      [read, _unread] = Notification.for_user!(actor: user)
      {:ok, _} = Notification.mark_read(read, actor: user)

      assert [%Notification{read_at: nil}] =
               Notification.for_user!(%{unread_only: true}, actor: user)
    end

    test "filters by type" do
      user = register_user!()
      :ok = Notification.fanout([row(user, %{}), row(user, %{type: :package_added})])

      assert [%Notification{type: :package_added}] =
               Notification.for_user!(%{types: [:package_added]}, actor: user)

      assert [_, _] =
               Notification.for_user!(
                 %{types: [:package_added, :channel_revision_published]},
                 actor: user
               )
    end

    test "search matches the package attribute, case-insensitively" do
      user = register_user!()
      firefox = package!("firefox-#{System.unique_integer([:positive])}")

      :ok = Notification.fanout([row(user, %{package_id: firefox.id}), row(user, %{})])

      assert [%Notification{package_id: id}] =
               Notification.for_user!(%{search: "FIRE"}, actor: user)

      assert id == firefox.id
    end

    test "search matches the channel name, change title and branch name" do
      user = register_user!()
      chan = channel!()
      change = change!(nil, %{state: :open, title: "ripgrep: 14.1.0 -> 14.1.1"})
      branch = change_branch!(change, "staging-next")

      :ok =
        Notification.fanout([
          row(user, %{channel_id: chan.id}),
          row(user, %{change_id: change.id}),
          row(user, %{change_branch_id: branch.id}),
          row(user, %{})
        ])

      assert [_] = Notification.for_user!(%{search: chan.name}, actor: user)
      assert [_] = Notification.for_user!(%{search: "ripgrep"}, actor: user)
      assert [_] = Notification.for_user!(%{search: "staging-next"}, actor: user)
      assert [] = Notification.for_user!(%{search: "nothing-matches-this"}, actor: user)
    end

    test "combines the filters" do
      user = register_user!()
      firefox = package!("firefox-#{System.unique_integer([:positive])}")

      :ok =
        Notification.fanout([
          row(user, %{type: :package_added, package_id: firefox.id}),
          row(user, %{type: :package_removed, package_id: firefox.id}),
          row(user, %{type: :package_added})
        ])

      assert [%Notification{type: :package_added, package_id: id}] =
               Notification.for_user!(
                 %{types: [:package_added], search: "firefox", unread_only: true},
                 actor: user
               )

      assert id == firefox.id
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

    test "broadcasts to the user's topic" do
      user = register_user!()
      :ok = Notification.fanout([row(user, %{})])
      [n] = Notification.for_user!(actor: user)
      Phoenix.PubSub.subscribe(Tracker.PubSub, "notifications:#{user.id}")

      {:ok, _} = Notification.mark_read(n, actor: user)

      assert_receive %Ash.Notifier.Notification{
        resource: Notification,
        action: %{name: :mark_read}
      }
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

    test "broadcasts to the user's topic" do
      user = register_user!()
      :ok = Notification.fanout([row(user, %{})])
      [n] = Notification.for_user!(actor: user)
      {:ok, n} = Notification.mark_read(n, actor: user)
      Phoenix.PubSub.subscribe(Tracker.PubSub, "notifications:#{user.id}")

      {:ok, _} = Notification.mark_unread(n, actor: user)

      assert_receive %Ash.Notifier.Notification{
        resource: Notification,
        action: %{name: :mark_unread}
      }
    end
  end
end

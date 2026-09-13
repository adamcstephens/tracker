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

    test "preserves saved and read state across a re-run" do
      user = register_user!()
      rows = [row(user, %{})]
      :ok = Notification.fanout(rows)
      [notification] = Notification.for_user!(actor: user)
      saved = Notification.save!(notification, actor: user)
      read = Notification.mark_read!(saved, actor: user)

      :ok = Notification.fanout(rows)

      assert [persisted] = Notification.for_user!(actor: user)
      assert persisted.id == notification.id
      assert persisted.saved
      assert persisted.read_at == read.read_at

      Notification.unsave!(persisted, actor: user)
      :ok = Notification.fanout(rows)

      assert [persisted] = Notification.for_user!(actor: user)
      assert persisted.id == notification.id
      refute persisted.saved
      assert persisted.read_at == read.read_at
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

    test "saved_only includes both read states but excludes unsaved and other owners" do
      user = register_user!()
      other = register_user!()

      :ok =
        Notification.fanout([
          row(user, %{occurred_at: ~U[2024-04-01 00:00:00Z]}),
          row(user, %{occurred_at: ~U[2024-03-01 00:00:00Z]}),
          row(user, %{occurred_at: ~U[2024-02-01 00:00:00Z]}),
          row(user, %{occurred_at: ~U[2024-01-01 00:00:00Z]}),
          row(other, %{})
        ])

      [saved_read, saved_unread, unsaved_read, unsaved_unread] =
        Notification.for_user!(actor: user)

      saved_read
      |> Notification.save!(actor: user)
      |> Notification.mark_read!(actor: user)

      Notification.save!(saved_unread, actor: user)
      Notification.mark_read!(unsaved_read, actor: user)
      [other_notification] = Notification.for_user!(actor: other)
      Notification.save!(other_notification, actor: other)

      assert [read, unread] = Notification.for_user!(%{saved_only: true}, actor: user)
      assert read.id == saved_read.id
      refute is_nil(read.read_at)
      assert unread.id == saved_unread.id
      assert is_nil(unread.read_at)

      expected_ids = [saved_read.id, saved_unread.id, unsaved_read.id, unsaved_unread.id]
      assert Enum.map(Notification.for_user!(actor: user), & &1.id) == expected_ids

      assert Enum.map(Notification.for_user!(%{saved_only: false}, actor: user), & &1.id) ==
               expected_ids
    end

    test "saved_only composes with revision, type, search and unread filters" do
      user = register_user!()
      channel = channel!()
      revision = channel_revision!(channel)
      other_revision = channel_revision!(channel)
      firefox = package!("firefox-#{System.unique_integer([:positive])}")
      attrs = %{type: :package_added, package_id: firefox.id, channel_revision_id: revision.id}
      unread = row(user, attrs)
      read = row(user, attrs)
      unsaved = row(user, attrs)

      :ok =
        Notification.fanout([
          unread,
          read,
          unsaved,
          row(user, %{attrs | type: :package_removed}),
          row(user, %{attrs | channel_revision_id: other_revision.id}),
          row(user, %{attrs | package_id: nil})
        ])

      for notification <- Notification.for_user!(actor: user),
          notification.dedup_key != unsaved.dedup_key do
        saved = Notification.save!(notification, actor: user)

        if notification.dedup_key == read.dedup_key do
          Notification.mark_read!(saved, actor: user)
        end
      end

      filters = %{
        saved_only: true,
        channel_revision_id: revision.id,
        types: [:package_added],
        search: "FIREFOX"
      }

      matches = Notification.for_user!(filters, actor: user)

      assert Enum.sort(Enum.map(matches, & &1.dedup_key)) ==
               Enum.sort([read.dedup_key, unread.dedup_key])

      assert [matching_unread] =
               Notification.for_user!(Map.put(filters, :unread_only, true), actor: user)

      assert matching_unread.dedup_key == unread.dedup_key
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

  describe "save/2 and unsave/2" do
    test "change saved state without changing either read state" do
      user = register_user!()
      :ok = Notification.fanout([row(user, %{})])
      [notification] = Notification.for_user!(actor: user)

      saved_unread = Notification.save!(notification, actor: user)
      assert saved_unread.saved
      assert is_nil(saved_unread.read_at)

      unsaved_unread = Notification.unsave!(saved_unread, actor: user)
      refute unsaved_unread.saved
      assert is_nil(unsaved_unread.read_at)

      read = Notification.mark_read!(unsaved_unread, actor: user)
      saved_read = Notification.save!(read, actor: user)
      assert saved_read.saved
      assert saved_read.read_at == read.read_at

      unsaved_read = Notification.unsave!(saved_read, actor: user)
      refute unsaved_read.saved
      assert unsaved_read.read_at == read.read_at
    end

    test "read updates preserve saved state, including from stale records" do
      user = register_user!()
      :ok = Notification.fanout([row(user, %{})])
      [notification] = Notification.for_user!(actor: user)
      Notification.save!(notification, actor: user)

      read = Notification.mark_read!(notification, actor: user)
      assert [persisted_read] = Notification.for_user!(actor: user)
      assert persisted_read.saved
      refute is_nil(persisted_read.read_at)

      Notification.mark_unread!(read, actor: user)
      assert [persisted] = Notification.for_user!(actor: user)
      assert persisted.saved
      assert is_nil(persisted.read_at)
    end

    test "saved updates preserve read changes made after the record was loaded" do
      user = register_user!()
      :ok = Notification.fanout([row(user, %{})])
      [notification] = Notification.for_user!(actor: user)
      read = Notification.mark_read!(notification, actor: user)

      Notification.save!(notification, actor: user)
      assert [saved] = Notification.for_user!(actor: user)
      assert saved.saved
      assert saved.read_at == read.read_at

      Notification.mark_unread!(saved, actor: user)
      Notification.unsave!(saved, actor: user)
      assert [unsaved] = Notification.for_user!(actor: user)
      refute unsaved.saved
      assert is_nil(unsaved.read_at)
    end

    test "only the owner can save or unsave a notification" do
      owner = register_user!()
      other = register_user!()
      :ok = Notification.fanout([row(owner, %{})])
      [notification] = Notification.for_user!(actor: owner)

      assert {:error, _} = Notification.save(notification, actor: other)
      assert {:error, _} = Notification.save(notification, actor: nil)
      assert [persisted] = Notification.for_user!(actor: owner)
      refute persisted.saved

      saved = Notification.save!(notification, actor: owner)
      assert {:error, _} = Notification.unsave(saved, actor: other)
      assert {:error, _} = Notification.unsave(saved, actor: nil)
      assert [persisted] = Notification.for_user!(actor: owner)
      assert persisted.saved
    end

    test "broadcasts saves and unsaves to the owner's notifications topic" do
      user = register_user!()
      :ok = Notification.fanout([row(user, %{})])
      [notification] = Notification.for_user!(actor: user)
      Phoenix.PubSub.subscribe(Tracker.PubSub, "notifications:#{user.id}")

      saved = Notification.save!(notification, actor: user)

      assert_receive %Ash.Notifier.Notification{
        resource: Notification,
        action: %{name: :save},
        data: saved_data
      }

      assert saved_data.id == notification.id
      assert saved_data.saved
      Notification.unsave!(saved, actor: user)

      assert_receive %Ash.Notifier.Notification{
        resource: Notification,
        action: %{name: :unsave},
        data: unsaved_data
      }

      assert unsaved_data.id == notification.id
      refute unsaved_data.saved
    end
  end
end

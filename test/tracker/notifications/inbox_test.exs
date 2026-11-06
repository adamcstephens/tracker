defmodule Tracker.Notifications.InboxTest do
  use Tracker.DataCase, async: true

  import Tracker.Fixtures

  alias Tracker.Notifications.{Inbox, Notification}

  defp package_notification!(user, revision, package, overrides \\ %{}) do
    notification!(
      user,
      Map.merge(
        %{
          type: :package_added,
          package_id: package.id,
          channel_id: revision.channel_id,
          channel_revision_id: revision.id
        },
        overrides
      )
    )
  end

  test "page counts ledger notifications and distinct packages without loading hidden members" do
    user = register_user!()
    channel = channel!()
    revision = channel_revision!(channel)
    package = package!()
    package_notification!(user, revision, package)
    package_notification!(user, revision, package, %{type: :package_removed})

    notification!(user, %{
      type: :channel_revision_published,
      channel_id: channel.id,
      channel_revision_id: revision.id
    })

    assert {:ok, page} = Inbox.page(%{}, user)
    assert page.count == 1
    assert page.notification_count == 3
    assert page.package_count == 1
    assert page.unread_count == 3
    assert [entry] = page.entries
    assert entry.revision_id == revision.id
    assert entry.notification_count == 3
    assert entry.package_count == 1
    assert entry.package_notification_count == 2
    assert entry.members == []
    assert entry.revision_notifications == []
    assert length(Notification.for_user!(actor: user)) == 3
  end

  test "lazy member loads limit package notifications without hiding the revision notification" do
    user = register_user!()
    channel = channel!()
    revision = channel_revision!(channel)

    for _ <- 1..8 do
      package_notification!(user, revision, package!())
    end

    published =
      notification!(user, %{
        type: :channel_revision_published,
        channel_id: channel.id,
        channel_revision_id: revision.id
      })

    assert {:ok, page} = Inbox.page(%{}, user)
    assert {:ok, [entry]} = Inbox.members(%{}, user, page.entries, limit: 3)
    assert length(entry.members) == 3
    assert Enum.all?(entry.members, &(&1.type == :package_added))
    assert Enum.map(entry.revision_notifications, & &1.id) == [published.id]
    assert entry.package_count == 8
    assert entry.notification_count == 9
    assert Enum.all?(Notification.for_user!(actor: user), &is_nil(&1.read_at))
  end

  test "actor view type search channel package and revision scopes compose before grouping" do
    user = register_user!()
    other = register_user!()
    channel = channel!()
    revision = channel_revision!(channel)
    package = package!("group-match-#{System.unique_integer([:positive])}")

    matching = package_notification!(user, revision, package) |> Notification.save!(actor: user)
    package_notification!(user, revision, package)

    package_notification!(user, revision, package, %{type: :package_removed})
    |> Notification.save!(actor: user)

    package_notification!(user, revision, package!()) |> Notification.save!(actor: user)

    package_notification!(user, channel_revision!(channel), package)
    |> Notification.save!(actor: user)

    package_notification!(user, channel_revision!(), package) |> Notification.save!(actor: user)
    package_notification!(other, revision, package) |> Notification.save!(actor: other)

    package_notification!(user, revision, package)
    |> Notification.save!(actor: user)
    |> Notification.mark_read!(actor: user)

    scope = %{
      unread_only: true,
      saved_only: true,
      types: [:package_added],
      search: package.attribute,
      channel_id: channel.id,
      package_id: package.id,
      channel_revision_id: revision.id
    }

    assert {:ok, page} = Inbox.page(scope, user)
    assert page.count == 1
    assert page.notification_count == 1
    assert page.package_count == 1
    assert page.unread_count == 1
    assert {:ok, [entry]} = Inbox.members(scope, user, page.entries, limit: 3)
    assert Enum.map(entry.members, & &1.id) == [matching.id]
    assert entry.revision_notifications == []
    assert {:ok, 1} = Inbox.mark_matching_read(scope, user, entry_key: entry.key)
    assert {:ok, empty} = Inbox.page(scope, user)
    assert empty.count == 0
    assert empty.notification_count == 0
    assert empty.entries == []
    assert length(Notification.for_user!(%{unread_only: true}, actor: user)) == 5
    assert Enum.all?(Notification.for_user!(actor: other), &is_nil(&1.read_at))
  end

  test "an empty type selection never becomes an unfiltered read or bulk update" do
    user = register_user!()
    notification = notification!(user)

    assert {:ok, page} = Inbox.page(%{types: []}, user)
    assert page.count == 0
    assert page.notification_count == 0
    assert page.unread_count == 0
    assert page.entries == []
    assert {:ok, 0} = Inbox.mark_matching_read(%{types: []}, user)
    assert %Notification{read_at: nil} = Ash.get!(Notification, notification.id, actor: user)
  end

  test "PR propagation and package notifications without a revision remain standalone" do
    user = register_user!()
    channel = channel!()
    revision = channel_revision!(channel)
    package = package!()
    change = change!()
    grouped = package_notification!(user, revision, package)

    standalone =
      for type <- [:package_change_opened, :package_change_merged, :change_propagated] do
        notification!(user, %{
          type: type,
          package_id: package.id,
          change_id: change.id,
          channel_id: channel.id,
          channel_revision_id: revision.id
        })
      end

    unlinked = notification!(user, %{type: :package_added, package_id: package.id})
    assert {:ok, page} = Inbox.page(%{}, user)
    assert page.count == 5
    assert page.notification_count == 5
    assert Enum.count(page.entries, &(&1.revision_id == revision.id)) == 1
    assert Enum.find(page.entries, &(&1.revision_id == revision.id)).notification.id == grouped.id

    standalone_ids =
      page.entries
      |> Enum.filter(&is_nil(&1.revision_id))
      |> Enum.map(& &1.notification.id)
      |> Enum.sort()

    assert standalone_ids == Enum.sort(Enum.map([unlinked | standalone], & &1.id))
  end

  test "grouped pages remain disjoint with tied timestamps and retain distinct revisions" do
    user = register_user!()
    channel = channel!()

    revisions =
      for _ <- 1..27 do
        revision = channel_revision!(channel)

        for _ <- 1..2 do
          package_notification!(user, revision, package!(), %{
            occurred_at: ~U[2026-10-01 00:00:00Z]
          })
        end

        revision
      end

    assert {:ok, first} = Inbox.page(%{}, user, offset: 0, limit: 25)
    assert {:ok, second} = Inbox.page(%{}, user, offset: 25, limit: 25)
    assert first.count == 27
    assert first.notification_count == 54
    assert length(first.entries) == 25
    assert length(second.entries) == 2
    first_ids = Enum.map(first.entries, & &1.revision_id)
    second_ids = Enum.map(second.entries, & &1.revision_id)
    assert MapSet.disjoint?(MapSet.new(first_ids), MapSet.new(second_ids))
    assert Enum.sort(first_ids ++ second_ids) == Enum.sort(Enum.map(revisions, & &1.id))
    assert {:ok, repeated} = Inbox.page(%{}, user, offset: 0, limit: 25)
    assert Enum.map(repeated.entries, & &1.key) == Enum.map(first.entries, & &1.key)
  end

  test "entry keys cannot broaden group reads to another actor's ledger" do
    user = register_user!()
    other = register_user!()
    channel = channel!()
    revision = channel_revision!(channel)
    own = package_notification!(user, revision, package!())
    foreign = package_notification!(other, revision, package!())
    foreign_standalone = notification!(other)

    assert {:ok, other_page} = Inbox.page(%{}, other)
    foreign_entry = Enum.find(other_page.entries, &(&1.notification.id == foreign_standalone.id))
    assert {:ok, 0} = Inbox.mark_matching_read(%{}, user, entry_key: foreign_entry.key)
    assert {:ok, 1} = Inbox.mark_matching_read(%{}, user, entry_key: revision.id)
    refute is_nil(Ash.get!(Notification, own.id, actor: user).read_at)
    assert %Notification{read_at: nil} = Ash.get!(Notification, foreign.id, actor: other)

    assert %Notification{read_at: nil} =
             Ash.get!(Notification, foreign_standalone.id, actor: other)
  end

  @tag :inbox_large_history
  test "a thousand-member revision remains one entry with a bounded lazy preview" do
    user = register_user!()
    channel = channel!()
    revision = channel_revision!(channel)
    first_package = package!()
    second_package = package!()
    run = System.unique_integer([:positive])

    grouped_rows =
      for number <- 1..1000 do
        %{
          user_id: user.id,
          type: :package_added,
          package_id: if(rem(number, 2) == 0, do: first_package.id, else: second_package.id),
          channel_id: channel.id,
          channel_revision_id: revision.id,
          occurred_at: ~U[2026-10-02 00:00:00Z],
          dedup_key: "large-inbox-#{run}-group-#{number}"
        }
      end

    standalone_rows =
      for number <- 1..26 do
        %{
          user_id: user.id,
          type: :channel_revision_published,
          occurred_at: ~U[2026-10-01 00:00:00Z],
          dedup_key: "large-inbox-#{run}-standalone-#{number}"
        }
      end

    assert :ok = Notification.fanout(grouped_rows ++ standalone_rows)
    assert {:ok, first} = Inbox.page(%{}, user, offset: 0, limit: 25)
    assert first.count == 27
    assert first.notification_count == 1026
    assert first.package_count == 2
    assert first.unread_count == 1026
    assert length(first.entries) == 25
    assert Enum.all?(first.entries, &(&1.members == [] and &1.revision_notifications == []))

    group = Enum.find(first.entries, &(&1.revision_id == revision.id))
    assert group.notification_count == 1000
    assert group.package_notification_count == 1000
    assert group.package_count == 2
    assert {:ok, [preview]} = Inbox.members(%{}, user, [group], limit: 3)
    assert length(preview.members) == 3
    assert preview.revision_notifications == []
    assert preview.notification_count == 1000
    assert preview.package_count == 2

    assert {:ok, second} = Inbox.page(%{}, user, offset: 25, limit: 25)
    assert second.count == 27
    assert length(second.entries) == 2
    assert Enum.all?(second.entries, &is_nil(&1.revision_id))

    assert MapSet.disjoint?(
             MapSet.new(first.entries, & &1.key),
             MapSet.new(second.entries, & &1.key)
           )
  end
end

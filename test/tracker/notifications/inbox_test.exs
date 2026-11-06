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

  defp propagation!(user, branch_name, occurred_at, overrides \\ %{}) do
    change = change!()
    branch = change_branch!(change, branch_name)

    notification!(
      user,
      Map.merge(
        %{
          type: :change_propagated,
          change_id: change.id,
          change_branch_id: branch.id,
          occurred_at: occurred_at
        },
        overrides
      )
    )
  end

  defp mutate_after_projection!(user, notification, transition) do
    handler = {__MODULE__, make_ref()}
    owner = self()

    :ok =
      :telemetry.attach(
        handler,
        [:ash, :notifications, :read, :stop],
        fn _event, _measurements, metadata, _config ->
          if self() == owner and metadata.resource == Notification and
               metadata.action == :for_inbox and get_in(metadata.actor.id) == user.id do
            :telemetry.detach(handler)

            case transition do
              :mark_read -> Notification.mark_read!(notification, actor: user)
              :unsave -> Notification.unsave!(notification, actor: user)
            end

            send(owner, {:changed_after_projection, transition})
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  @tag :inbox_projection_race
  test "read state changes after projection never leave an uncounted revision entry" do
    user = register_user!()
    revision = channel_revision!()
    notification = package_notification!(user, revision, package!())
    mutate_after_projection!(user, notification, :mark_read)

    assert {:ok, page} = Inbox.page(%{unread_only: true}, user)
    assert_receive {:changed_after_projection, :mark_read}
    assert [entry] = page.entries
    assert entry.notification_count == 1
    assert entry.package_notification_count == 1
    assert entry.unread_count == 1
    assert {:ok, fresh} = Inbox.page(%{unread_only: true}, user)
    assert fresh.entries == []
    assert fresh.notification_count == 0
  end

  @tag :inbox_projection_race
  test "saved state changes after projection never leave an uncounted propagation digest" do
    user = register_user!()

    notification =
      propagation!(user, "master", ~U[2026-10-02 12:00:00Z])
      |> Notification.save!(actor: user)

    mutate_after_projection!(user, notification, :unsave)

    assert {:ok, page} = Inbox.page(%{saved_only: true}, user)
    assert_receive {:changed_after_projection, :unsave}
    assert [entry] = page.entries
    assert entry.notification_count == 1
    assert entry.propagation_count == 1
    assert entry.unread_count == 1
    assert {:ok, fresh} = Inbox.page(%{saved_only: true}, user)
    assert fresh.entries == []
    assert fresh.notification_count == 0
  end

  @tag :propagation_grouping
  test "linked propagations share revision entries with exact separate counts and bounded children" do
    user = register_user!()
    revision = channel_revision!()
    package_notification!(user, revision, package!())
    published = notification!(user, %{channel_revision_id: revision.id})

    propagations =
      for _ <- 1..8 do
        propagation!(user, "master", ~U[2026-10-02 12:00:00Z], %{
          channel_revision_id: revision.id
        })
      end

    assert {:ok, page} = Inbox.page(%{}, user)
    assert page.count == 1
    assert page.notification_count == 10
    assert [entry] = page.entries
    assert entry.key == "revision:#{revision.id}"
    assert entry.kind == :revision
    assert entry.package_notification_count == 1
    assert entry.revision_notification_count == 1
    assert entry.propagation_count == 8
    assert entry.propagation_notifications == []
    assert {:ok, [preview]} = Inbox.members(%{}, user, [entry], limit: 3)
    assert length(preview.members) == 1
    assert Enum.map(preview.revision_notifications, & &1.id) == [published.id]
    assert length(preview.propagation_notifications) == 3

    assert Enum.all?(
             preview.propagation_notifications,
             &(&1.id in Enum.map(propagations, fn n -> n.id end))
           )

    assert {:ok, 10} = Inbox.mark_matching_read(%{}, user, entry_key: entry.key)
    assert Enum.all?(Notification.for_user!(actor: user), &(not is_nil(&1.read_at)))
  end

  @tag :propagation_grouping
  test "propagation-only revisions remain grouped without inventing revision notifications" do
    user = register_user!()
    revision = channel_revision!()

    for _ <- 1..4 do
      propagation!(user, "master", ~U[2026-10-02 12:00:00Z], %{
        channel_revision_id: revision.id
      })
    end

    assert {:ok, page} = Inbox.page(%{}, user)
    assert page.count == 1
    assert [entry] = page.entries
    assert entry.revision_id == revision.id
    assert entry.notification_count == 4
    assert entry.propagation_count == 4
    assert entry.revision_notification_count == 0
    assert entry.package_notification_count == 0
    assert {:ok, [preview]} = Inbox.members(%{}, user, [entry], limit: 3)
    assert preview.members == []
    assert preview.revision_notifications == []
    assert length(preview.propagation_notifications) == 3
  end

  @tag :propagation_grouping
  test "revision-less propagation groups use branch target and UTC calendar day across unique changes" do
    user = register_user!()
    for _ <- 1..8, do: propagation!(user, "master", ~U[2026-10-02 12:00:00Z])
    propagation!(user, "master", ~U[2026-10-02 00:00:00Z])
    propagation!(user, "master", ~U[2026-10-02 23:59:59Z])
    propagation!(user, "staging", ~U[2026-10-02 12:00:00Z])
    propagation!(user, "master", ~U[2026-10-03 00:00:00Z])

    assert {:ok, page} = Inbox.page(%{}, user)
    assert page.count == 3
    assert page.notification_count == 12
    assert page.unread_count == 12
    entry = Enum.find(page.entries, &(&1.key == "propagation:2026-10-02:master"))
    assert entry.kind == :propagation
    assert entry.revision_id == nil
    assert entry.branch_name == "master"
    assert entry.propagation_day == ~D[2026-10-02]
    assert entry.notification_count == 10
    assert entry.propagation_count == 10
    assert entry.revision_notification_count == 0
    assert entry.propagation_notifications == []
    assert {:ok, [preview]} = Inbox.members(%{}, user, [entry], limit: 3)
    assert length(preview.propagation_notifications) == 3
    assert preview.members == []
    assert preview.revision_notifications == []
    assert {:ok, 10} = Inbox.mark_matching_read(%{}, user, entry_key: entry.key)
    assert {:ok, unread} = Inbox.page(%{unread_only: true}, user)
    assert unread.notification_count == 2
    refute Enum.any?(unread.entries, &(&1.key == entry.key))
  end

  @tag :propagation_grouping
  test "digest children counts and group reads retain actor search saved type branch and day scope" do
    user = register_user!()
    other = register_user!()

    matching =
      propagation!(user, "master", ~U[2026-10-02 12:00:00Z]) |> Notification.save!(actor: user)

    propagation!(user, "master", ~U[2026-10-02 13:00:00Z])

    propagation!(user, "master", ~U[2026-10-02 14:00:00Z])
    |> Notification.save!(actor: user)
    |> Notification.mark_read!(actor: user)

    propagation!(other, "master", ~U[2026-10-02 12:00:00Z]) |> Notification.save!(actor: other)
    propagation!(user, "staging", ~U[2026-10-02 12:00:00Z]) |> Notification.save!(actor: user)
    propagation!(user, "master", ~U[2026-10-03 12:00:00Z]) |> Notification.save!(actor: user)
    scope = %{types: [:change_propagated], search: "master", unread_only: true, saved_only: true}

    assert {:ok, page} = Inbox.page(scope, user)
    assert page.count == 2
    entry = Enum.find(page.entries, &(&1.key == "propagation:2026-10-02:master"))
    assert entry.notification_count == 1
    assert entry.propagation_count == 1
    assert entry.unread_count == 1
    assert {:ok, [preview]} = Inbox.members(scope, user, [entry], limit: 3)
    assert Enum.map(preview.propagation_notifications, & &1.id) == [matching.id]
    assert {:ok, 1} = Inbox.mark_matching_read(scope, user, entry_key: entry.key)
    assert length(Notification.for_user!(%{unread_only: true}, actor: user)) == 3
    assert Enum.all?(Notification.for_user!(actor: other), &is_nil(&1.read_at))
  end

  @tag :propagation_grouping
  test "digest grouping precedes page boundaries and batches exact bounded members" do
    user = register_user!()

    for number <- 1..27, _ <- 1..4 do
      propagation!(user, "master", DateTime.add(~U[2026-10-01 12:00:00Z], number, :day))
    end

    assert {:ok, first} = Inbox.page(%{}, user, limit: 25)
    assert {:ok, second} = Inbox.page(%{}, user, offset: 25, limit: 25)
    assert first.count == 27
    assert first.notification_count == 108
    assert length(first.entries) == 25
    assert length(second.entries) == 2

    assert MapSet.disjoint?(
             MapSet.new(first.entries, & &1.key),
             MapSet.new(second.entries, & &1.key)
           )

    assert {:ok, previews} = Inbox.members(%{}, user, first.entries, limit: 3)
    assert Enum.all?(previews, &(length(&1.propagation_notifications) == 3))
    assert Enum.all?(previews, &(&1.notification_count == 4 and &1.propagation_count == 4))

    assert Enum.all?(previews, fn entry ->
             Enum.all?(
               entry.propagation_notifications,
               &(&1.change_branch.branch_name == entry.branch_name)
             )
           end)
  end

  test "Inbox removes package scope while flat ledger reads retain it" do
    user = register_user!()
    channel = channel!()
    revision = channel_revision!(channel)
    package = package!()
    matching = package_notification!(user, revision, package)
    package_notification!(user, revision, package!())

    assert is_nil(
             Ash.Resource.Info.action(Notification, :for_inbox).arguments
             |> Enum.find(&(&1.name == :package_id))
           )

    assert is_nil(
             Ash.Resource.Info.action(Notification, :matching).arguments
             |> Enum.find(&(&1.name == :package_id))
           )

    assert [notification] = Notification.for_user!(%{package_id: package.id}, actor: user)
    assert notification.id == matching.id
    assert {:ok, channels} = Inbox.filter_options(user)
    assert Enum.map(channels, & &1.id) == [channel.id]
  end

  test "channel-only propagation references retain their actual target in a digest" do
    user = register_user!()
    channel = channel!()

    for _ <- 1..2 do
      notification!(user, %{
        type: :change_propagated,
        channel_id: channel.id,
        change_id: change!().id,
        occurred_at: ~U[2026-10-02 12:00:00Z]
      })
    end

    assert {:ok, page} = Inbox.page(%{}, user)
    assert [entry] = page.entries
    assert entry.kind == :propagation
    assert entry.branch_name == channel.name
    assert entry.key == "propagation:2026-10-02:#{channel.name}"
    assert entry.propagation_count == 2
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

  test "actor view type search channel and revision scopes compose before grouping" do
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

  test "PR and package notifications without a revision remain standalone" do
    user = register_user!()
    channel = channel!()
    revision = channel_revision!(channel)
    package = package!()
    change = change!()
    grouped = package_notification!(user, revision, package)

    standalone =
      for type <- [:package_change_opened, :package_change_merged] do
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
    assert page.count == 4
    assert page.notification_count == 4
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
    assert {:ok, 1} = Inbox.mark_matching_read(%{}, user, entry_key: "revision:#{revision.id}")
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

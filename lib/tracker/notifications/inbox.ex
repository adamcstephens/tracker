defmodule Tracker.Notifications.Inbox do
  @moduledoc "Actor-scoped, filter-first projection of the notification ledger."

  alias Tracker.Accounts.User
  alias Tracker.Notifications.Notification
  require Ash.Query

  defmodule Entry do
    @moduledoc false
    use TypedStruct

    typedstruct do
      field :key, String.t(), enforce: true
      field :kind, :revision | :notification, enforce: true
      field :revision_id, integer()
      field :occurred_at, DateTime.t(), enforce: true
      field :notification, Notification.t(), enforce: true
      field :notification_count, non_neg_integer(), default: 0
      field :package_count, non_neg_integer(), default: 0
      field :revision_notification_count, non_neg_integer(), default: 0
      field :package_notification_count, non_neg_integer(), default: 0
      field :propagation_count, non_neg_integer(), default: 0
      field :unread_count, non_neg_integer(), default: 0
      field :members, [Notification.t()], default: []
      field :revision_notifications, [Notification.t()], default: []
      field :propagation_notifications, [Notification.t()], default: []
    end
  end

  defmodule Page do
    @moduledoc false
    use TypedStruct

    typedstruct do
      field :entries, [Entry.t()], default: []
      field :count, non_neg_integer(), default: 0
      field :notification_count, non_neg_integer(), default: 0
      field :package_count, non_neg_integer(), default: 0
      field :unread_count, non_neg_integer(), default: 0
      field :offset, non_neg_integer(), default: 0
      field :limit, pos_integer(), default: 25
    end
  end

  @references [
    :package,
    :channel,
    :change,
    channel_revision: [:channel],
    change_branch: [:change]
  ]

  def page(scope, %User{} = actor, opts \\ []) do
    scope = Map.new(scope)
    offset = Keyword.get(opts, :offset, 0)
    limit = Keyword.get(opts, :limit, 25)

    with {:ok, page} <-
           Notification.for_inbox(scope,
             actor: actor,
             page: [offset: offset, limit: limit, count: true]
           ),
         {:ok, counts} <- matching_counts(scope, actor) do
      {:ok,
       %Page{
         entries: Enum.map(page.results, &entry/1),
         count: page.count,
         notification_count: counts.notification_count,
         package_count: counts.package_count,
         unread_count: counts.unread_count,
         offset: page.offset,
         limit: page.limit
       }}
    else
      {:error, error} -> {:error, error}
    end
  end

  def members(scope, %User{} = actor, entries, opts \\ []) do
    limit = Keyword.get(opts, :limit, 3)
    groups = Enum.reject(entries, &(&1.kind == :notification))

    package_query =
      matching_query(scope, actor)
      |> Ash.Query.filter(type in [:package_version_changed, :package_added, :package_removed])
      |> Ash.Query.sort(occurred_at: :desc, id: :desc)
      |> Ash.Query.limit(limit)
      |> Ash.Query.load(@references)

    revision_query =
      matching_query(scope, actor)
      |> Ash.Query.sort(occurred_at: :desc, id: :desc)
      |> Ash.Query.limit(limit)
      |> Ash.Query.load(@references)

    with {:ok, notifications} <-
           Ash.load(
             Enum.map(groups, & &1.notification),
             [
               inbox_members: package_query,
               revision_notifications: revision_query,
               propagation_notifications: revision_query
             ],
             actor: actor,
             reuse_values?: false
           ) do
      by_id = Map.new(notifications, &{&1.id, &1})

      {:ok,
       Enum.map(entries, fn %Entry{} = entry ->
         case Map.fetch(by_id, entry.notification.id) do
           {:ok, notification} ->
             %{
               entry
               | members: notification.inbox_members,
                 revision_notifications: notification.revision_notifications,
                 propagation_notifications: notification.propagation_notifications
             }

           :error ->
             entry
         end
       end)}
    else
      {:error, error} -> {:error, error}
    end
  end

  def mark_matching_read(scope, %User{} = actor, opts \\ []) do
    scope =
      scope
      |> Map.new()
      |> Map.put(:unread_only, true)
      |> then(fn scope ->
        case Keyword.fetch(opts, :entry_key) do
          {:ok, key} -> Map.put(scope, :entry_key, key)
          :error -> scope
        end
      end)

    query = matching_query(scope, actor)

    with {:ok, count} <- Ash.count(query, actor: actor) do
      case Notification.mark_read(query, %{},
             actor: actor,
             bulk_options: [
               strategy: [:atomic, :atomic_batches],
               return_records?: false,
               return_errors?: true,
               notify?: true
             ]
           ) do
        %Ash.BulkResult{status: :success} -> {:ok, count}
        %Ash.BulkResult{errors: errors} -> {:error, Ash.Error.to_error_class(errors)}
      end
    else
      {:error, error} -> {:error, error}
    end
  end

  def filter_options(%User{} = actor) do
    with {:ok, channels} <-
           Notification.matching(%{},
             actor: actor,
             query: [
               filter: [channel_id: [is_nil: false]],
               distinct: [:channel_id],
               sort: [channel_id: :asc],
               select: [:channel_id]
             ],
             load: [:channel]
           ) do
      {:ok, channels |> Enum.map(& &1.channel) |> Enum.sort_by(& &1.name)}
    else
      {:error, error} -> {:error, error}
    end
  end

  defp matching_query(scope, %User{} = actor) do
    Notification
    |> Ash.Query.for_read(:matching, Map.new(scope), actor: actor)
  end

  defp matching_counts(scope, %User{} = actor) do
    matching_query(scope, actor)
    |> Ash.aggregate(
      [
        {:notification_count, :count},
        {:package_count, :count, field: :package_id, uniq?: true},
        {:unread_count, :count, query: [filter: [read_at: [is_nil: true]]]}
      ],
      actor: actor
    )
  end

  defp entry(%Notification{} = notification) do
    kind =
      case notification.entry_key do
        "revision:" <> _ -> :revision
        "notification:" <> _ -> :notification
      end

    %Entry{
      key: notification.entry_key,
      kind: kind,
      revision_id: if(kind == :revision, do: notification.channel_revision_id),
      occurred_at: notification.occurred_at,
      notification: notification,
      notification_count: notification.aggregates.inbox_notification_count,
      package_count: notification.aggregates.inbox_package_count,
      package_notification_count: notification.aggregates.inbox_package_notification_count,
      revision_notification_count: notification.aggregates.inbox_revision_notification_count,
      propagation_count: notification.aggregates.inbox_propagation_count,
      unread_count: notification.aggregates.inbox_unread_count
    }
  end
end

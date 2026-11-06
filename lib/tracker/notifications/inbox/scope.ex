defmodule Tracker.Notifications.Inbox.Scope do
  @moduledoc false
  use Ash.Resource.Preparation
  require Ash.Query

  @impl Ash.Resource.Preparation
  def prepare(query, _opts, context) do
    user_id = get_in(context.actor.id)

    query =
      if is_nil(user_id) do
        Ash.Query.filter(query, false)
      else
        Ash.Query.filter(query, user_id == ^user_id)
      end

    query =
      Enum.reduce(
        [:channel_revision_id, :channel_id, :package_id, :entry_key],
        query,
        fn field, query ->
          case Ash.Query.get_argument(query, field) do
            nil -> query
            value -> Ash.Query.filter(query, ^[{field, value}])
          end
        end
      )

    query =
      if Ash.Query.get_argument(query, :unread_only) do
        Ash.Query.filter(query, is_nil(read_at))
      else
        query
      end

    query =
      if Ash.Query.get_argument(query, :saved_only) do
        Ash.Query.filter(query, saved)
      else
        query
      end

    query =
      case Ash.Query.get_argument(query, :types) do
        nil -> query
        types -> Ash.Query.filter(query, type in ^types)
      end

    case Ash.Query.get_argument(query, :search) do
      nil ->
        query

      search ->
        if to_string(search) == "" do
          query
        else
          Ash.Query.filter(
            query,
            contains(package.attribute, ^search) or
              contains(channel.name, ^search) or
              contains(change.title, ^search) or
              contains(change_branch.branch_name, ^search)
          )
        end
    end
  end
end

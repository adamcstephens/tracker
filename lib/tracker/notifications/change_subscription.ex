defmodule Tracker.Notifications.ChangeSubscription do
  @moduledoc """
  A user's subscription to a change's propagation. A nil `channel_id` means
  "any branch/channel"; a set `channel_id` scopes to propagation reaching that
  one channel.
  """

  use Ash.Resource,
    otp_app: :tracker,
    domain: Tracker.Notifications,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "change_subscriptions"
    repo Tracker.Repo

    references do
      reference :user, on_delete: :delete
      reference :change, on_delete: :delete
      reference :channel, on_delete: :delete
    end
  end

  code_interface do
    define :subscribe, args: [:change_id, {:optional, :channel_id}]
    define :find, args: [:change_id, {:optional, :channel_id}], not_found_error?: false
    define :destroy
    define :for_user
    define :subscribers_of_change, args: [:change_id, {:optional, :channel_id}]
  end

  actions do
    defaults [:read, :destroy]

    create :subscribe do
      description "Subscribe the actor to a change, optionally scoped to one channel."
      accept [:change_id, :channel_id]
      upsert? true
      upsert_identity :unique_change_subscription
      upsert_fields [:updated_at]

      change relate_actor(:user)
    end

    read :find do
      description "Fetch the actor's subscription to a change at the given channel scope, if any."
      get? true
      argument :change_id, :integer, allow_nil?: false
      argument :channel_id, :integer

      filter expr(
               change_id == ^arg(:change_id) and
                 ((is_nil(^arg(:channel_id)) and is_nil(channel_id)) or
                    channel_id == ^arg(:channel_id))
             )
    end

    read :for_user do
      description "List the actor's change subscriptions, newest first."
      prepare build(sort: [inserted_at: :desc])
    end

    read :subscribers_of_change do
      description """
      Change subscriptions matching a change for fan-out: any-branch (nil channel)
      subscriptions always match; channel-targeted subscriptions match the mapped channel.
      """

      argument :change_id, :integer, allow_nil?: false
      argument :channel_id, :integer

      filter expr(
               change_id == ^arg(:change_id) and
                 (is_nil(channel_id) or channel_id == ^arg(:channel_id))
             )
    end
  end

  policies do
    policy action_type(:create) do
      authorize_if expr(not is_nil(^actor(:id)))
    end

    policy action_type([:read, :destroy]) do
      authorize_if expr(user_id == ^actor(:id))
    end
  end

  attributes do
    integer_primary_key :id
    timestamps()
  end

  relationships do
    belongs_to :user, Tracker.Accounts.User, attribute_type: :uuid, allow_nil?: false
    belongs_to :change, Tracker.Nixpkgs.Change, attribute_type: :integer, allow_nil?: false
    belongs_to :channel, Tracker.Nixpkgs.Channel, attribute_type: :integer
  end

  identities do
    identity :unique_change_subscription, [:user_id, :change_id, :channel_id] do
      nils_distinct? false
    end
  end
end

defmodule Tracker.Notifications.ChannelSubscription do
  @moduledoc """
  A user's subscription to a channel, notifying them when new revisions are
  published to it.
  """

  use Ash.Resource,
    otp_app: :tracker,
    domain: Tracker.Notifications,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "channel_subscriptions"
    repo Tracker.Repo

    references do
      reference :user, on_delete: :delete
      reference :channel, on_delete: :delete
    end
  end

  code_interface do
    define :subscribe, args: [:channel_id]
    define :find, args: [:channel_id], not_found_error?: false
    define :destroy
    define :for_user
  end

  actions do
    defaults [:read, :destroy]

    create :subscribe do
      description "Subscribe the actor to a channel's new revisions."
      accept [:channel_id]
      upsert? true
      upsert_identity :unique_channel_subscription
      upsert_fields [:updated_at]

      change relate_actor(:user)
    end

    read :find do
      description "Fetch the actor's subscription to a channel, if any."
      get? true
      argument :channel_id, :integer, allow_nil?: false

      filter expr(channel_id == ^arg(:channel_id))
    end

    read :for_user do
      description "List the actor's channel subscriptions, newest first."
      prepare build(sort: [inserted_at: :desc])
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
    belongs_to :channel, Tracker.Nixpkgs.Channel, attribute_type: :integer, allow_nil?: false
  end

  identities do
    identity :unique_channel_subscription, [:user_id, :channel_id]
  end
end

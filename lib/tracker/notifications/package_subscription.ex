defmodule Tracker.Notifications.PackageSubscription do
  @moduledoc """
  A user's subscription to a package. A nil `channel_id` means "all channels";
  a set `channel_id` scopes the subscription to a single channel.

  `events` selects which notification types the subscription fans out, named
  after the `Notification` types themselves so fan-out is a membership test.
  """

  use Ash.Resource,
    otp_app: :tracker,
    domain: Tracker.Notifications,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  @event_types Tracker.Notifications.Notification.package_event_types()
  @default_events [:package_version_changed, :package_added, :package_removed]

  postgres do
    table "package_subscriptions"
    repo Tracker.Repo

    migration_defaults events: ~s(["package_version_changed", "package_added", "package_removed"])

    references do
      reference :user, on_delete: :delete
      reference :package, on_delete: :delete
      reference :channel, on_delete: :delete
    end
  end

  code_interface do
    define :subscribe, args: [:package_id, {:optional, :channel_id}]
    define :find, args: [:package_id, {:optional, :channel_id}], not_found_error?: false
    define :set_events, args: [:events]
    define :destroy
    define :for_user
    define :subscribers_in_channel_scope, args: [:channel_id]
    define :subscribers_of_packages, args: [:package_ids]
  end

  actions do
    defaults [:read, :destroy]

    create :subscribe do
      description "Subscribe the actor to a package, optionally scoped to one channel."
      accept [:package_id, :channel_id]
      upsert? true
      upsert_identity :unique_package_subscription
      upsert_fields [:updated_at]

      change relate_actor(:user)
    end

    update :set_events do
      description "Replace the events this subscription notifies on."
      accept [:events]
    end

    read :find do
      description "Fetch the actor's subscription to a package at the given channel scope, if any."
      get? true
      argument :package_id, :integer, allow_nil?: false
      argument :channel_id, :integer

      filter expr(
               package_id == ^arg(:package_id) and
                 ((is_nil(^arg(:channel_id)) and is_nil(channel_id)) or
                    channel_id == ^arg(:channel_id))
             )
    end

    read :for_user do
      description "List the actor's package subscriptions, newest first."
      prepare build(sort: [inserted_at: :desc])
    end

    read :subscribers_in_channel_scope do
      description "Package subscriptions whose channel scope includes the given channel (system fan-out)."
      argument :channel_id, :integer, allow_nil?: false
      filter expr(is_nil(channel_id) or channel_id == ^arg(:channel_id))
    end

    read :subscribers_of_packages do
      description "Package subscriptions for any of the given packages, with their channel (system fan-out)."
      argument :package_ids, {:array, :integer}, allow_nil?: false
      prepare build(load: [:channel])
      filter expr(package_id in ^arg(:package_ids))
    end
  end

  policies do
    policy action_type(:create) do
      authorize_if expr(not is_nil(^actor(:id)))
    end

    policy action_type([:read, :update, :destroy]) do
      authorize_if expr(user_id == ^actor(:id))
    end
  end

  attributes do
    integer_primary_key :id

    attribute :events, {:array, :atom} do
      allow_nil? false
      public? true
      default @default_events
      constraints min_length: 1, items: [one_of: @event_types]
    end

    timestamps()
  end

  relationships do
    belongs_to :user, Tracker.Accounts.User, attribute_type: :uuid, allow_nil?: false
    belongs_to :package, Tracker.Nixpkgs.Package, attribute_type: :integer, allow_nil?: false
    belongs_to :channel, Tracker.Nixpkgs.Channel, attribute_type: :integer
  end

  identities do
    identity :unique_package_subscription, [:user_id, :package_id, :channel_id] do
      nils_distinct? false
    end
  end
end

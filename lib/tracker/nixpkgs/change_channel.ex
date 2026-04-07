defmodule Tracker.Nixpkgs.ChangeChannel do
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "change_channels"
    repo Tracker.Repo
  end

  code_interface do
    define :read
    define :create
  end

  actions do
    defaults [:read]

    create :create do
      accept [:change_id, :channel_id, :channel_revision_id, :landed_at]
      upsert? true
      upsert_identity :unique_change_channel
      upsert_fields [:channel_revision_id, :landed_at, :updated_at]
    end
  end

  attributes do
    integer_primary_key :id

    attribute :landed_at, :utc_datetime do
      allow_nil? false
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :change, Tracker.Nixpkgs.Change, attribute_type: :integer, allow_nil?: false

    belongs_to :channel, Tracker.Nixpkgs.Channel, attribute_type: :integer, allow_nil?: false

    belongs_to :channel_revision, Tracker.Nixpkgs.ChannelRevision,
      attribute_type: :integer,
      allow_nil?: true
  end

  identities do
    identity :unique_change_channel, [:change_id, :channel_id]
  end
end

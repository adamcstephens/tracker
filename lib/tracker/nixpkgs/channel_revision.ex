defmodule Tracker.Nixpkgs.ChannelRevision do
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "channel_revisions"
    repo Tracker.Repo
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:channel, :revision]
      upsert? true
      upsert_identity :unique_channel_revision
    end

    update :record_result do
      accept [:result]
    end
  end

  attributes do
    integer_primary_key :id

    attribute :channel, :string do
      allow_nil? false
      public? true
    end

    attribute :revision, :string do
      allow_nil? false
      public? true
    end

    attribute :result, :atom, constraints: [one_of: [:success, :partial_success, :error]]

    timestamps()
  end

  identities do
    identity :unique_channel_revision, [:channel, :revision]
  end
end

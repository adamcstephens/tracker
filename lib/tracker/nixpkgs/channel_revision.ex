defmodule Tracker.Nixpkgs.ChannelRevision do
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "channel_revisions"
    repo Tracker.Repo
  end

  code_interface do
    define :find, args: [:channel, :revision]
  end

  actions do
    defaults [:read]

    read :find do
      get? true

      argument :channel, :string do
        allow_nil? false
      end

      argument :revision, :string do
        allow_nil? false
      end

      filter expr(channel == ^arg(:channel) and revision == ^arg(:revision))
    end

    create :create do
      primary? true
      accept [:channel, :revision, :released_at]
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

    attribute :released_at, :utc_datetime, public?: true

    timestamps()
  end

  identities do
    identity :unique_channel_revision, [:channel, :revision]
  end
end

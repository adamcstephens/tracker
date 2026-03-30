defmodule Tracker.Nixpkgs.ChannelRevision do
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "channel_revisions"
    repo Tracker.Repo
  end

  code_interface do
    define :read
    define :find, args: [:channel, :revision]
    define :create
    define :list_by_channel, args: [:channel]
    define :record_result
    define :by_channel, args: [:channel]
    define :distinct_channels
    define :find_by_short_hash, args: [:channel, :short_hash]
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
      accept [:channel, :revision, :released_at, :previous_channel_revision_id]
      upsert? true
      upsert_identity :unique_channel_revision
      upsert_fields [:released_at, :updated_at]
    end

    read :list_by_channel do
      argument :channel, :string do
        allow_nil? false
      end

      pagination do
        offset? true
        countable true
        default_limit 15
      end

      prepare build(sort: [{:released_at, :desc}])
      filter expr(channel == ^arg(:channel))
    end

    update :record_result do
      accept [:result]
    end

    read :by_channel do
      argument :channel, :string do
        allow_nil? false
      end

      filter expr(channel == ^arg(:channel))
    end

    read :distinct_channels do
      prepare build(distinct: [:channel], sort: [:channel])
    end

    read :find_by_short_hash do
      get? true

      argument :channel, :string do
        allow_nil? false
      end

      argument :short_hash, :string do
        allow_nil? false
      end

      filter expr(
               channel == ^arg(:channel) and
                 fragment("? LIKE ? || '%'", revision, ^arg(:short_hash))
             )
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

    attribute :released_at, :utc_datetime, allow_nil?: false, public?: true

    timestamps()
  end

  relationships do
    belongs_to :previous_channel_revision, __MODULE__ do
      attribute_type :integer
      allow_nil? true
    end
  end

  identities do
    identity :unique_channel_revision, [:channel, :revision]
  end
end

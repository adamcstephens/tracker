defmodule Tracker.Nixpkgs.PackageRevision do
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "package_revisions"
    repo Tracker.Repo
  end

  actions do
    defaults [:read, create: [:version]]

    create :load do
      accept [:version, :channel_revision_id, :package_id]
      upsert? true
      upsert_identity :unique_package_revision
      upsert_fields [:version, :updated_at]
    end
  end

  attributes do
    integer_primary_key :id

    attribute :version, :string do
      allow_nil? false
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :package, Tracker.Nixpkgs.Package, attribute_type: :integer, allow_nil?: false

    belongs_to :channel_revision, Tracker.Nixpkgs.ChannelRevision,
      attribute_type: :integer,
      allow_nil?: false
  end

  calculations do
    calculate :channel, :string, expr(channel_revision.channel)
    calculate :revision_hash, :string, expr(channel_revision.revision)
    calculate :released_at, :utc_datetime, expr(channel_revision.released_at)
  end

  identities do
    identity :unique_package_revision, [:channel_revision_id, :package_id]
  end
end

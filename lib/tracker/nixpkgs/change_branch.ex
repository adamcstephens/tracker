defmodule Tracker.Nixpkgs.ChangeBranch do
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "change_branches"
    repo Tracker.Repo
  end

  code_interface do
    define :read
    define :create
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:change_id, :branch_id, :channel_revision_id, :arrived_at]
      upsert? true
      upsert_identity :unique_change_branch
      upsert_fields [:channel_revision_id, :arrived_at, :updated_at]
    end
  end

  attributes do
    integer_primary_key :id

    attribute :arrived_at, :utc_datetime do
      allow_nil? false
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :change, Tracker.Nixpkgs.Change, attribute_type: :integer, allow_nil?: false

    belongs_to :branch, Tracker.Nixpkgs.Branch, attribute_type: :integer, allow_nil?: false

    belongs_to :channel_revision, Tracker.Nixpkgs.ChannelRevision,
      attribute_type: :integer,
      allow_nil?: true
  end

  identities do
    identity :unique_change_branch, [:change_id, :branch_id]
  end
end

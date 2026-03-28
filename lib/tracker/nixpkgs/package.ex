defmodule Tracker.Nixpkgs.Package do
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "packages"
    repo Tracker.Repo
  end

  code_interface do
    define :bulk_upsert, args: [:attribute]
  end

  actions do
    defaults [:read]

    create :create do
      accept [:attribute]
    end

    create :bulk_upsert do
      accept [:attribute]
      upsert? true
      upsert_identity :unique_attribute
      upsert_fields :updated_at
    end
  end

  attributes do
    integer_primary_key :id

    attribute :attribute, :string do
      allow_nil? false
      public? true
    end

    timestamps()
  end

  relationships do
    has_many :revisions, Tracker.Nixpkgs.PackageRevision
  end

  identities do
    identity :unique_attribute, [:attribute]
  end
end

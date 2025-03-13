defmodule Tracker.Nixpkgs.Package do
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "packages"
    repo Tracker.Repo
  end

  actions do
    defaults [:read]

    create :create do
      accept [:attribute]
    end

    create :load do
      accept [:attribute]
      upsert? true
      upsert_identity :unique_attribute

      argument :revision, :map do
        allow_nil? false
      end

      change manage_relationship(:revision, :revisions, on_no_match: {:create, :load})
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

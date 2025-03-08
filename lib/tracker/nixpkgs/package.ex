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
  end

  attributes do
    integer_primary_key :id

    attribute :attribute, :string do
      allow_nil? false
      public? true
    end

    timestamps()
  end

  identities do
    identity :unique_attribute, [:attribute]
  end
end

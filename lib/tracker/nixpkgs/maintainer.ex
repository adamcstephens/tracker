defmodule Tracker.Nixpkgs.Maintainer do
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "maintainers"
    repo Tracker.Repo
  end

  actions do
    defaults [:read]

    create :bulk_upsert do
      accept [:github_id, :name, :email, :github, :matrix]
      upsert? true
      upsert_identity :unique_github_id
      upsert_fields [:name, :email, :github, :matrix, :updated_at]
    end
  end

  attributes do
    integer_primary_key :id

    attribute :github_id, :integer do
      allow_nil? false
      public? true
    end

    attribute :name, :string, public?: true
    attribute :email, :string, public?: true
    attribute :github, :string, public?: true
    attribute :matrix, :string, public?: true

    timestamps()
  end

  identities do
    identity :unique_github_id, [:github_id]
  end
end

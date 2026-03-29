defmodule Tracker.Nixpkgs.Team do
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "teams"
    repo Tracker.Repo
  end

  actions do
    defaults [:read]

    create :bulk_upsert do
      accept [:short_name, :scope, :github, :github_id]
      upsert? true
      upsert_identity :unique_short_name
      upsert_fields [:scope, :github, :github_id, :updated_at]
    end
  end

  attributes do
    integer_primary_key :id

    attribute :short_name, :string do
      allow_nil? false
      public? true
    end

    attribute :scope, :string, public?: true
    attribute :github, :string, public?: true
    attribute :github_id, :integer, public?: true

    timestamps()
  end

  relationships do
    many_to_many :members, Tracker.Nixpkgs.Maintainer do
      through Tracker.Nixpkgs.TeamMember
      source_attribute_on_join_resource :team_id
      destination_attribute_on_join_resource :maintainer_id
    end
  end

  identities do
    identity :unique_short_name, [:short_name]
  end
end

defmodule Tracker.Nixpkgs.TeamMember do
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "team_members"
    repo Tracker.Repo
  end

  code_interface do
    define :read
    define :load
  end

  actions do
    defaults [:read]

    create :load do
      accept [:team_id, :maintainer_id]
      upsert? true
      upsert_identity :unique_team_member
      upsert_fields [:updated_at]
    end
  end

  attributes do
    integer_primary_key :id
    timestamps()
  end

  relationships do
    belongs_to :team, Tracker.Nixpkgs.Team, attribute_type: :integer, allow_nil?: false

    belongs_to :maintainer, Tracker.Nixpkgs.Maintainer,
      attribute_type: :integer,
      allow_nil?: false
  end

  identities do
    identity :unique_team_member, [:team_id, :maintainer_id]
  end
end

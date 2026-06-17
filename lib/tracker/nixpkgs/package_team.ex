defmodule Tracker.Nixpkgs.PackageTeam do
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "package_teams"
    repo Tracker.Repo
  end

  code_interface do
    define :read
    define :load
  end

  actions do
    defaults [:read]

    create :load do
      accept [:package_id, :team_id]
      upsert? true
      upsert_identity :unique_package_team
      upsert_fields [:updated_at]
    end
  end

  attributes do
    integer_primary_key :id
    timestamps()
  end

  relationships do
    belongs_to :package, Tracker.Nixpkgs.Package, attribute_type: :integer, allow_nil?: false
    belongs_to :team, Tracker.Nixpkgs.Team, attribute_type: :integer, allow_nil?: false
  end

  # 5 columns: id, package_id, team_id, inserted_at, updated_at
  @ash_cols 5
  @max_batch div(65_535, @ash_cols)

  def bulk_create_all(records) do
    Tracker.Nixpkgs.BulkCreate.run!(records, __MODULE__, :load, @max_batch)
  end

  identities do
    identity :unique_package_team, [:package_id, :team_id]
  end
end

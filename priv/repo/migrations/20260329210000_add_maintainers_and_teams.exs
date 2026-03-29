defmodule Tracker.Repo.Migrations.AddMaintainersAndTeams do
  use Ecto.Migration

  def change do
    create table(:maintainers, primary_key: false) do
      add :id, :bigserial, null: false, primary_key: true
      add :github_id, :bigint, null: false
      add :name, :text
      add :email, :text
      add :github, :text
      add :matrix, :text

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:maintainers, [:github_id], name: "maintainers_unique_github_id_index")

    create table(:teams, primary_key: false) do
      add :id, :bigserial, null: false, primary_key: true
      add :short_name, :text, null: false
      add :scope, :text
      add :github, :text
      add :github_id, :bigint

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:teams, [:short_name], name: "teams_unique_short_name_index")

    create table(:package_maintainers, primary_key: false) do
      add :id, :bigserial, null: false, primary_key: true

      add :package_id,
          references(:packages,
            column: :id,
            name: "package_maintainers_package_id_fkey",
            type: :bigint,
            prefix: "public"
          ),
          null: false

      add :maintainer_id,
          references(:maintainers,
            column: :id,
            name: "package_maintainers_maintainer_id_fkey",
            type: :bigint,
            prefix: "public"
          ),
          null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:package_maintainers, [:package_id, :maintainer_id],
             name: "package_maintainers_unique_index"
           )

    create table(:package_teams, primary_key: false) do
      add :id, :bigserial, null: false, primary_key: true

      add :package_id,
          references(:packages,
            column: :id,
            name: "package_teams_package_id_fkey",
            type: :bigint,
            prefix: "public"
          ),
          null: false

      add :team_id,
          references(:teams,
            column: :id,
            name: "package_teams_team_id_fkey",
            type: :bigint,
            prefix: "public"
          ),
          null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:package_teams, [:package_id, :team_id],
             name: "package_teams_unique_index"
           )

    create table(:team_members, primary_key: false) do
      add :id, :bigserial, null: false, primary_key: true

      add :team_id,
          references(:teams,
            column: :id,
            name: "team_members_team_id_fkey",
            type: :bigint,
            prefix: "public"
          ),
          null: false

      add :maintainer_id,
          references(:maintainers,
            column: :id,
            name: "team_members_maintainer_id_fkey",
            type: :bigint,
            prefix: "public"
          ),
          null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:team_members, [:team_id, :maintainer_id],
             name: "team_members_unique_index"
           )
  end
end

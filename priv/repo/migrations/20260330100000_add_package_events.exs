defmodule Tracker.Repo.Migrations.AddPackageEvents do
  use Ecto.Migration

  def change do
    alter table(:channel_revisions) do
      add :previous_channel_revision_id,
          references(:channel_revisions, on_delete: :nilify_all)
    end

    create table(:package_events) do
      add :type, :string, null: false
      add :package_id, references(:packages, on_delete: :delete_all), null: false

      add :channel_revision_id, references(:channel_revisions, on_delete: :delete_all),
        null: false

      timestamps(default: fragment("now()"))
    end

    create index(:package_events, [:package_id])
    create index(:package_events, [:channel_revision_id])
    create index(:package_events, [:type])
  end
end

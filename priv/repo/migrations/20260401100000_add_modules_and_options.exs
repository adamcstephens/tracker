defmodule Tracker.Repo.Migrations.AddModulesAndOptions do
  use Ecto.Migration

  def change do
    create table(:modules) do
      add :declaration, :text, null: false
      add :display_name, :text, null: false

      timestamps(default: fragment("now()"))
    end

    create unique_index(:modules, [:declaration])

    create table(:options) do
      add :name, :text, null: false
      add :module_id, references(:modules, on_delete: :nilify_all)

      timestamps(default: fragment("now()"))
    end

    create unique_index(:options, [:name])
    create index(:options, [:module_id])

    create table(:option_revisions) do
      add :option_id, references(:options, on_delete: :delete_all), null: false

      add :channel_revision_id, references(:channel_revisions, on_delete: :delete_all),
        null: false

      add :description, :text
      add :type, :text
      add :default, :text
      add :example, :text
      add :read_only, :boolean, default: false
      add :loc, {:array, :text}
      add :declarations, {:array, :text}
      add :related_packages, :text

      timestamps(default: fragment("now()"))
    end

    create unique_index(:option_revisions, [:channel_revision_id, :option_id])
    create index(:option_revisions, [:option_id])

    create table(:option_events) do
      add :type, :string, null: false
      add :option_id, references(:options, on_delete: :delete_all), null: false

      add :channel_revision_id, references(:channel_revisions, on_delete: :delete_all),
        null: false

      timestamps(default: fragment("now()"))
    end

    create index(:option_events, [:option_id])
    create index(:option_events, [:channel_revision_id])
  end
end

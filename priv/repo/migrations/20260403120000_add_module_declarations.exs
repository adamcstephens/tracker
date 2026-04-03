defmodule Tracker.Repo.Migrations.AddModuleDeclarations do
  use Ecto.Migration

  def up do
    create table(:module_declarations) do
      add :path, :text, null: false
      add :module_id, references(:modules, on_delete: :delete_all), null: false

      timestamps(default: fragment("now()"))
    end

    create unique_index(:module_declarations, [:path])
    create index(:module_declarations, [:module_id])

    # Drop old declaration column and index
    drop unique_index(:modules, [:declaration])

    alter table(:modules) do
      remove :declaration
    end

    # Add unique index on display_name
    create unique_index(:modules, [:display_name])
  end

  def down do
    drop unique_index(:modules, [:display_name])

    alter table(:modules) do
      add :declaration, :text
    end

    execute "ALTER TABLE modules ALTER COLUMN declaration SET NOT NULL"
    create unique_index(:modules, [:declaration])

    drop table(:module_declarations)
  end
end

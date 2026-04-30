defmodule Tracker.Repo.Migrations.DropModuleAddFiles do
  @moduledoc """
  Drops the synthetic Module abstraction and adds first-class Files.

  - Removes `options.module_id` and `option_packages.module_id`.
  - Drops `module_declarations` and `modules` tables.
  - Creates `files` and `option_revision_files`.

  This is a one-way migration. Channel revisions must be re-imported to
  populate file membership data.
  """

  use Ecto.Migration

  def up do
    alter table(:options) do
      remove :module_id
    end

    alter table(:option_packages) do
      remove :module_id
    end

    drop table(:module_declarations)
    drop table(:modules)

    create table(:files, primary_key: false) do
      add :id, :bigserial, null: false, primary_key: true
      add :path, :text, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:files, [:path], name: "files_unique_path_index")

    create table(:option_revision_files, primary_key: false) do
      add :id, :bigserial, null: false, primary_key: true

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :option_revision_id,
          references(:option_revisions,
            column: :id,
            name: "option_revision_files_option_revision_id_fkey",
            type: :bigint,
            prefix: "public"
          ),
          null: false

      add :file_id,
          references(:files,
            column: :id,
            name: "option_revision_files_file_id_fkey",
            type: :bigint,
            prefix: "public"
          ),
          null: false
    end

    create unique_index(:option_revision_files, [:option_revision_id, :file_id],
             name: "option_revision_files_unique_revision_file_index"
           )
  end
end

defmodule Tracker.Repo.Migrations.AddOptionPackages do
  use Ecto.Migration

  def change do
    create table(:option_packages) do
      add :option_id, references(:options, on_delete: :delete_all), null: false
      add :package_id, references(:packages, on_delete: :delete_all), null: false

      timestamps(default: fragment("now()"))
    end

    create unique_index(:option_packages, [:option_id, :package_id])
    create index(:option_packages, [:package_id])
  end
end

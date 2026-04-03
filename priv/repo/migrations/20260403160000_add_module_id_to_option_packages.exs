defmodule Tracker.Repo.Migrations.AddModuleIdToOptionPackages do
  use Ecto.Migration

  def change do
    alter table(:option_packages) do
      add :module_id, references(:modules, on_delete: :delete_all)
    end

    create index(:option_packages, [:module_id])
  end
end

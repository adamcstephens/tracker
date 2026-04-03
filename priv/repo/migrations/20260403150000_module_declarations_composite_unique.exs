defmodule Tracker.Repo.Migrations.ModuleDeclarationsCompositeUnique do
  use Ecto.Migration

  def up do
    drop unique_index(:module_declarations, [:path])
    create unique_index(:module_declarations, [:path, :module_id])
  end

  def down do
    drop unique_index(:module_declarations, [:path, :module_id])
    create unique_index(:module_declarations, [:path])
  end
end

defmodule Tracker.Repo.Migrations.AddPackageIdIndexToPackageRevisions do
  use Ecto.Migration

  def change do
    create index(:package_revisions, [:package_id])
  end
end

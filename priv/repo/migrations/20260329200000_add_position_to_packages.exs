defmodule Tracker.Repo.Migrations.AddPositionToPackages do
  use Ecto.Migration

  def change do
    alter table(:packages) do
      add :position, :text
    end
  end
end

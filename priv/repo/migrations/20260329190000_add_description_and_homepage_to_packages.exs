defmodule Tracker.Repo.Migrations.AddDescriptionAndHomepageToPackages do
  use Ecto.Migration

  def change do
    alter table(:packages) do
      add :description, :text
      add :homepage, :text
    end
  end
end

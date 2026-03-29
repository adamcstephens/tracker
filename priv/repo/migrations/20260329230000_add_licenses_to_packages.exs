defmodule Tracker.Repo.Migrations.AddLicensesToPackages do
  use Ecto.Migration

  def change do
    alter table(:packages) do
      add :licenses, {:array, :text}
    end
  end
end

defmodule Tracker.Repo.Migrations.MultiRole do
  @moduledoc """
  Replaces the single `role` column with a `roles` array.
  """

  use Ecto.Migration

  def up do
    alter table(:users) do
      remove :role
      add :roles, {:array, :text}, default: ["user"], null: false
    end
  end

  def down do
    alter table(:users) do
      remove :roles
      add :role, :text, default: "user"
    end
  end
end

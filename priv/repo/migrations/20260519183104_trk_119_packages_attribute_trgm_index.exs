defmodule Tracker.Repo.Migrations.Trk119PackagesAttributeTrgmIndex do
  use Ecto.Migration

  def up do
    execute(
      "CREATE INDEX IF NOT EXISTS packages_attribute_trgm_idx ON packages USING GIN (attribute gin_trgm_ops)"
    )
  end

  def down do
    execute("DROP INDEX IF EXISTS packages_attribute_trgm_idx")
  end
end

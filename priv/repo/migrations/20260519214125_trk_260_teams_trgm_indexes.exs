defmodule Tracker.Repo.Migrations.Trk260TeamsTrgmIndexes do
  use Ecto.Migration

  def up do
    execute(
      "CREATE INDEX IF NOT EXISTS teams_short_name_trgm_idx ON teams USING GIN (short_name gin_trgm_ops)"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS teams_scope_trgm_idx ON teams USING GIN (scope gin_trgm_ops)"
    )
  end

  def down do
    execute("DROP INDEX IF EXISTS teams_short_name_trgm_idx")
    execute("DROP INDEX IF EXISTS teams_scope_trgm_idx")
  end
end

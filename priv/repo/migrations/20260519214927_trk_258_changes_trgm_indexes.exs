defmodule Tracker.Repo.Migrations.Trk258ChangesTrgmIndexes do
  use Ecto.Migration

  def up do
    execute(
      "CREATE INDEX IF NOT EXISTS changes_title_trgm_idx ON changes USING GIN (title gin_trgm_ops)"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS changes_author_trgm_idx ON changes USING GIN (author gin_trgm_ops)"
    )
  end

  def down do
    execute("DROP INDEX IF EXISTS changes_title_trgm_idx")
    execute("DROP INDEX IF EXISTS changes_author_trgm_idx")
  end
end

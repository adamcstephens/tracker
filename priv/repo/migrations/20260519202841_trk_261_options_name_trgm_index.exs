defmodule Tracker.Repo.Migrations.Trk261OptionsNameTrgmIndex do
  use Ecto.Migration

  def up do
    execute(
      "CREATE INDEX IF NOT EXISTS options_name_trgm_idx ON options USING GIN (name gin_trgm_ops)"
    )
  end

  def down do
    execute("DROP INDEX IF EXISTS options_name_trgm_idx")
  end
end

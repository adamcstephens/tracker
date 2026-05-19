defmodule Tracker.Repo.Migrations.Trk259MaintainersGithubTrgmIndex do
  use Ecto.Migration

  def up do
    execute(
      "CREATE INDEX IF NOT EXISTS maintainers_github_trgm_idx ON maintainers USING GIN (github gin_trgm_ops)"
    )
  end

  def down do
    execute("DROP INDEX IF EXISTS maintainers_github_trgm_idx")
  end
end

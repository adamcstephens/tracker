defmodule Tracker.Repo.Migrations.AddGithubIndexToMaintainers do
  use Ecto.Migration

  def change do
    create unique_index(:maintainers, [:github], name: "maintainers_unique_github_index")
  end
end

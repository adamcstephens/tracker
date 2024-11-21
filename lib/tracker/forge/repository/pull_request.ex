defmodule Tracker.Forge.Repository.PullRequest do
  use Ash.Resource, domain: Tracker.Forge, data_layer: AshSqlite.DataLayer

  sqlite do
    table "pull_requests"
    repo Tracker.Repo
  end

  actions do
    defaults [:read]

    create :create
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :pr_id, :string
  end
end

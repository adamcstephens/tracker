defmodule Tracker.Repo.Migrations.AddOptionsResultToChannelRevisions do
  use Ecto.Migration

  def change do
    alter table(:channel_revisions) do
      add :options_result, :string
    end
  end
end

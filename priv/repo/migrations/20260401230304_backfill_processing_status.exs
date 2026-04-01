defmodule Tracker.Repo.Migrations.BackfillProcessingStatus do
  use Ecto.Migration

  def up do
    # Mark all existing changes as :processed since they completed processing
    # (they have a record, meaning upsert_change succeeded).
    # New changes will start as :pending and be set to their terminal status
    # by the updated worker.
    execute "UPDATE changes SET processing_status = 'processed' WHERE processing_status = 'pending'"
  end

  def down do
    execute "UPDATE changes SET processing_status = 'pending' WHERE processing_status = 'processed'"
  end
end

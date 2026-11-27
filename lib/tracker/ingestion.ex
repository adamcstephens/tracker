defmodule Tracker.Ingestion do
  @moduledoc "Ingestion tracking and admin-only, read-only investigation tools."
  use Ash.Domain,
    otp_app: :tracker,
    extensions: [AshAi]

  tools do
    tool :list_ingestion_runs, Tracker.Ingestion.IngestionRun, :list_ingestion_runs do
      description "List runs overlapping the requested UTC window, including unfinished runs. Results are paginated. Each run includes counts for every pipeline status and details for at most 100 unfinished pipelines. No raw errors are exposed."
      action_parameters([])
      select [:id, :type, :status, :started_at, :completed_at]

      load [
        :pipeline_counts,
        unfinished_pipelines: [
          :id,
          :channel_id,
          :status,
          :active_steps,
          :completed_steps,
          :failed_step
        ]
      ]

      load_strict?(true)
    end
  end

  resources do
    resource Tracker.Ingestion.IngestionRun
    resource Tracker.Ingestion.Pipeline
  end
end

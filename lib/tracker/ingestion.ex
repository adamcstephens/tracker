defmodule Tracker.Ingestion do
  use Ash.Domain,
    otp_app: :tracker

  resources do
    resource Tracker.Ingestion.IngestionRun
    resource Tracker.Ingestion.Pipeline
  end
end

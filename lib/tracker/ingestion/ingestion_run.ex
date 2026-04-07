defmodule Tracker.Ingestion.IngestionRun do
  use Ash.Resource,
    otp_app: :tracker,
    domain: Tracker.Ingestion,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "ingestion_runs"
    repo Tracker.Repo
  end

  code_interface do
    define :create
    define :read
    define :mark_completed
    define :mark_failed
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:type, :started_at]

      change set_attribute(:status, :running)
    end

    update :mark_completed do
      change set_attribute(:status, :completed)
      change set_attribute(:completed_at, &DateTime.utc_now/0)
    end

    update :mark_failed do
      change set_attribute(:status, :failed)
      change set_attribute(:completed_at, &DateTime.utc_now/0)
    end
  end

  attributes do
    integer_primary_key :id

    attribute :type, :atom do
      allow_nil? false
      constraints one_of: [:cron_update, :backfill]
    end

    attribute :status, :atom do
      allow_nil? false
      constraints one_of: [:running, :completed, :failed]
    end

    attribute :started_at, :utc_datetime do
      allow_nil? false
    end

    attribute :completed_at, :utc_datetime

    timestamps()
  end

  relationships do
    has_many :pipelines, Tracker.Ingestion.Pipeline
  end
end

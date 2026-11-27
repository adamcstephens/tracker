defmodule Tracker.Ingestion.IngestionRun do
  @moduledoc "Tracks ingestion runs and provides an admin-only, bounded investigation read."
  use Ash.Resource,
    otp_app: :tracker,
    domain: Tracker.Ingestion,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "ingestion_runs"
    repo Tracker.Repo
  end

  code_interface do
    define :create
    define :read
    define :list_ingestion_runs, args: [:window_start, :window_end]
    define :mark_completed
    define :mark_failed
  end

  actions do
    defaults [:read]

    read :list_ingestion_runs do
      description "List ingestion runs overlapping a UTC time window, including unfinished runs."
      argument :window_start, :utc_datetime, allow_nil?: false
      argument :window_end, :utc_datetime, allow_nil?: false

      pagination do
        offset? true
        default_limit 50
        max_page_size 50
        required? true
      end

      prepare build(sort: [started_at: :desc, id: :desc])

      filter expr(
               started_at <= ^arg(:window_end) and
                 (is_nil(completed_at) or completed_at >= ^arg(:window_start))
             )
    end

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

  policies do
    policy action(:list_ingestion_runs) do
      access_type :strict
      authorize_if {Tracker.Accounts.Checks.ActorHasRole, role: :admin}
    end

    policy action([:create, :read, :mark_completed, :mark_failed]) do
      authorize_if always()
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

    has_many :unfinished_pipelines, Tracker.Ingestion.Pipeline do
      destination_attribute :ingestion_run_id
      read_action :list_unfinished
    end
  end

  calculations do
    calculate :pipeline_counts,
              :map,
              expr(%{
                pending: pending_count,
                running: running_count,
                completed: completed_count,
                failed: failed_count,
                stuck: stuck_count
              })
  end

  aggregates do
    for status <- [:pending, :running, :completed, :failed, :stuck] do
      count :"#{status}_count", :pipelines do
        filter expr(status == ^status)
      end
    end
  end
end

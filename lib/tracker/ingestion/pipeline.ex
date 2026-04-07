defmodule Tracker.Ingestion.Pipeline do
  use Ash.Resource,
    otp_app: :tracker,
    domain: Tracker.Ingestion,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "ingestion_pipelines"
    repo Tracker.Repo
  end

  code_interface do
    define :create
    define :read
    define :find, args: [:channel, :revision]
    define :start
    define :complete_step, args: [:step]
    define :set_channel_revision_id, args: [:channel_revision_id]
    define :mark_completed
    define :mark_failed, args: [:failed_step, :error]
    define :retry_from_step
    define :last_completed_for_channel, args: [:channel]
    define :for_channel, args: [:channel]
    define :next_pending_for_channel, args: [:channel]
    define :for_run, args: [:ingestion_run_id]
  end

  actions do
    defaults [:read]

    create :create do
      primary? true

      accept [
        :channel,
        :revision,
        :base_url,
        :released_at,
        :active_steps,
        :sequence,
        :ingestion_run_id,
        :predecessor_id
      ]

      change set_attribute(:status, :pending)
      change set_attribute(:completed_steps, [])
    end

    read :find do
      get? true

      argument :channel, :string, allow_nil?: false
      argument :revision, :string, allow_nil?: false

      filter expr(channel == ^arg(:channel) and revision == ^arg(:revision))
    end

    read :next_pending_for_channel do
      argument :channel, :string, allow_nil?: false

      prepare build(sort: [{:sequence, :asc}], limit: 1)
      filter expr(channel == ^arg(:channel) and status == :pending)
    end

    read :last_completed_for_channel do
      argument :channel, :string, allow_nil?: false

      prepare build(sort: [{:released_at, :desc}], limit: 1)
      filter expr(channel == ^arg(:channel) and status == :completed)
    end

    read :for_channel do
      argument :channel, :string, allow_nil?: false

      filter expr(channel == ^arg(:channel))
    end

    read :for_run do
      argument :ingestion_run_id, :integer, allow_nil?: false

      filter expr(ingestion_run_id == ^arg(:ingestion_run_id))
    end

    update :start do
      validate Tracker.Ingestion.Pipeline.Validations.PredecessorCompleted
      change set_attribute(:status, :running)
    end

    update :complete_step do
      argument :step, :atom, allow_nil?: false

      manual Tracker.Ingestion.Pipeline.CompleteStep
    end

    update :set_channel_revision_id do
      argument :channel_revision_id, :integer, allow_nil?: false

      change set_attribute(:channel_revision_id, arg(:channel_revision_id))
    end

    update :mark_completed do
      change set_attribute(:status, :completed)
    end

    update :mark_failed do
      argument :failed_step, :atom, allow_nil?: false
      argument :error, :string

      change set_attribute(:status, :failed)
      change set_attribute(:failed_step, arg(:failed_step))
      change set_attribute(:error, arg(:error))
    end

    update :retry_from_step do
      change set_attribute(:status, :running)
      change set_attribute(:failed_step, nil)
      change set_attribute(:error, nil)
    end
  end

  attributes do
    integer_primary_key :id

    attribute :channel, :string do
      allow_nil? false
      public? true
    end

    attribute :revision, :string do
      allow_nil? false
      public? true
    end

    attribute :base_url, :string do
      allow_nil? false
    end

    attribute :released_at, :utc_datetime do
      allow_nil? false
      public? true
    end

    attribute :channel_revision_id, :integer

    attribute :status, :atom do
      allow_nil? false
      constraints one_of: [:pending, :running, :completed, :failed]
    end

    attribute :active_steps, {:array, :atom} do
      allow_nil? false
    end

    attribute :completed_steps, {:array, :atom} do
      allow_nil? false
      default []
    end

    attribute :failed_step, :atom,
      constraints: [
        one_of: [
          :create_revision,
          :load_packages,
          :detect_package_events,
          :load_options,
          :link_options,
          :detect_option_events,
          :finalize
        ]
      ]

    attribute :error, :string

    attribute :sequence, :integer do
      allow_nil? false
    end

    timestamps()
  end

  relationships do
    belongs_to :ingestion_run, Tracker.Ingestion.IngestionRun do
      attribute_type :integer
      allow_nil? false
    end

    belongs_to :predecessor, Tracker.Ingestion.Pipeline do
      attribute_type :integer
      allow_nil? true
      attribute_writable? true
    end
  end

  identities do
    identity :unique_pipeline_channel_revision, [:channel, :revision]
  end
end

defmodule Tracker.Nixpkgs.OptionFileSpan do
  @moduledoc """
  Validity-interval ("span") of an option↔file membership within a channel.

  Keyed on `(channel_id, option_id, file_id)` with an empty fingerprint —
  membership only, so a span is open while the file declares the option and
  closes when it no longer does. Keyed on `option_id` (not a revision id),
  bounded by option existence as an ingestion invariant. Overlap prevented
  per-channel by the `btree_gist` EXCLUDE constraint.
  """
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "option_file_spans"
    repo Tracker.Repo

    custom_statements do
      statement :option_file_spans_no_overlap do
        up "ALTER TABLE option_file_spans ADD CONSTRAINT option_file_spans_no_overlap EXCLUDE USING gist (channel_id WITH =, option_id WITH =, file_id WITH =, valid WITH &&)"
        down "ALTER TABLE option_file_spans DROP CONSTRAINT option_file_spans_no_overlap"
      end

      statement :option_file_spans_current do
        up "CREATE INDEX option_file_spans_current ON option_file_spans (channel_id, option_id, file_id) WHERE upper_inf(valid)"
        down "DROP INDEX option_file_spans_current"
      end
    end
  end

  code_interface do
    define :read
    define :at, args: [:channel_id, :at]
    define :options_for_files_at, args: [:channel_id, :at, :file_ids]
    define :files_for_options_at, args: [:channel_id, :at, :option_ids]
  end

  actions do
    defaults [:read]

    read :open_for_channel do
      description "Currently-open spans (unbounded upper) for a channel."
      argument :channel_id, :integer, allow_nil?: false
      filter expr(channel_id == ^arg(:channel_id) and fragment("upper_inf(?)", valid))
    end

    read :at do
      description "Spans valid at a point in time for a channel."
      argument :channel_id, :integer, allow_nil?: false
      argument :at, :utc_datetime, allow_nil?: false

      filter expr(
               channel_id == ^arg(:channel_id) and
                 fragment("? @> ?::timestamptz", valid, ^arg(:at))
             )
    end

    read :options_for_files_at do
      description "Membership spans for any of the given files, valid at a point in a channel; loads the declared option."
      argument :channel_id, :integer, allow_nil?: false
      argument :at, :utc_datetime, allow_nil?: false
      argument :file_ids, {:array, :integer}, allow_nil?: false

      prepare build(load: [:option])

      filter expr(
               channel_id == ^arg(:channel_id) and
                 file_id in ^arg(:file_ids) and
                 fragment("? @> ?::timestamptz", valid, ^arg(:at))
             )
    end

    read :files_for_options_at do
      description "Membership spans for the given options, valid at a point in a channel; loads the declaring file."
      argument :channel_id, :integer, allow_nil?: false
      argument :at, :utc_datetime, allow_nil?: false
      argument :option_ids, {:array, :integer}, allow_nil?: false

      prepare build(load: [:file])

      filter expr(
               channel_id == ^arg(:channel_id) and
                 option_id in ^arg(:option_ids) and
                 fragment("? @> ?::timestamptz", valid, ^arg(:at))
             )
    end

    create :open do
      accept [:channel_id, :option_id, :file_id, :valid]
    end

    update :close do
      argument :closed_at, :utc_datetime, allow_nil?: false

      change atomic_update(
               :valid,
               expr(
                 fragment("tstzrange(lower(?), ?::timestamptz, '[)')", valid, ^arg(:closed_at))
               )
             )
    end
  end

  attributes do
    integer_primary_key :id

    attribute :valid, Tracker.Nixpkgs.Types.TstzRange do
      allow_nil? false
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :channel, Tracker.Nixpkgs.Channel, attribute_type: :integer, allow_nil?: false
    belongs_to :option, Tracker.Nixpkgs.Option, attribute_type: :integer, allow_nil?: false
    belongs_to :file, Tracker.Nixpkgs.File, attribute_type: :integer, allow_nil?: false
  end

  @doc """
  The `SpanEngine.Spec` driving option↔file membership spans: keyed on
  `(option_id, file_id)` within a channel with an empty fingerprint, so a span
  is open exactly while the file declares the option. A file move (same option,
  new path) closes the old `file_id` key and opens the new one.
  """
  @spec spec() :: Tracker.Nixpkgs.SpanEngine.Spec.t()
  def spec do
    Tracker.Nixpkgs.SpanEngine.Spec.new(
      resource: __MODULE__,
      key_columns: [:option_id, :file_id],
      payload_columns: []
    )
  end
end

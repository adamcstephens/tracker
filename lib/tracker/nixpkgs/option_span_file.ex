defmodule Tracker.Nixpkgs.OptionSpanFile do
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
    table "option_span_files"
    repo Tracker.Repo

    custom_statements do
      statement :option_span_files_no_overlap do
        up "ALTER TABLE option_span_files ADD CONSTRAINT option_span_files_no_overlap EXCLUDE USING gist (channel_id WITH =, option_id WITH =, file_id WITH =, valid WITH &&)"
        down "ALTER TABLE option_span_files DROP CONSTRAINT option_span_files_no_overlap"
      end

      statement :option_span_files_current do
        up "CREATE INDEX option_span_files_current ON option_span_files (channel_id, option_id, file_id) WHERE upper_inf(valid)"
        down "DROP INDEX option_span_files_current"
      end
    end
  end

  code_interface do
    define :read
  end

  actions do
    defaults [:read]
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
end

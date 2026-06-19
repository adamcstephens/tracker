defmodule Tracker.Nixpkgs.OptionSpan do
  @moduledoc """
  Validity-interval ("span") of an option's metadata within a channel.

  One row per *change*, keyed on `(channel_id, option_id)`. Overlap prevented
  per-channel by the `btree_gist` EXCLUDE constraint. The fingerprint is a hash
  of the metadata payload (`description`, `type`, `default`, `example`,
  `read_only`, `loc`, `related_packages`); a span closes and reopens when it
  changes. See `Tracker.Nixpkgs.PackageSpan` for the shared span mechanics.
  """
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "option_spans"
    repo Tracker.Repo

    custom_statements do
      statement :option_spans_no_overlap do
        up "ALTER TABLE option_spans ADD CONSTRAINT option_spans_no_overlap EXCLUDE USING gist (channel_id WITH =, option_id WITH =, valid WITH &&)"
        down "ALTER TABLE option_spans DROP CONSTRAINT option_spans_no_overlap"
      end

      statement :option_spans_current do
        up "CREATE INDEX option_spans_current ON option_spans (channel_id, option_id) WHERE upper_inf(valid)"
        down "DROP INDEX option_spans_current"
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

    attribute :description, :string, public?: true
    attribute :type, :string, public?: true
    attribute :default, :string, public?: true
    attribute :example, :string, public?: true

    attribute :read_only, :boolean do
      default false
      public? true
    end

    attribute :loc, {:array, :string}, public?: true
    attribute :related_packages, :string, public?: true

    timestamps()
  end

  relationships do
    belongs_to :channel, Tracker.Nixpkgs.Channel, attribute_type: :integer, allow_nil?: false
    belongs_to :option, Tracker.Nixpkgs.Option, attribute_type: :integer, allow_nil?: false
  end
end

defmodule Tracker.Nixpkgs.OptionPackageSpan do
  @moduledoc """
  Validity-interval ("span") of an option↔package link within a channel.

  Keyed on `(channel_id, option_id, package_id)` with an empty fingerprint —
  membership only, so a span is open while the option references the package and
  closes when it no longer does. Overlap prevented per-channel by the
  `btree_gist` EXCLUDE constraint.
  """
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "option_package_spans"
    repo Tracker.Repo

    custom_statements do
      statement :option_package_spans_no_overlap do
        up "ALTER TABLE option_package_spans ADD CONSTRAINT option_package_spans_no_overlap EXCLUDE USING gist (channel_id WITH =, option_id WITH =, package_id WITH =, valid WITH &&)"
        down "ALTER TABLE option_package_spans DROP CONSTRAINT option_package_spans_no_overlap"
      end

      statement :option_package_spans_current do
        up "CREATE INDEX option_package_spans_current ON option_package_spans (channel_id, option_id, package_id) WHERE upper_inf(valid)"
        down "DROP INDEX option_package_spans_current"
      end
    end
  end

  code_interface do
    define :read
    define :at, args: [:channel_id, :at]
    define :packages_for_options_at, args: [:channel_id, :at, :option_ids]
    define :open_for_packages, args: [:package_ids]
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

    read :packages_for_options_at do
      description "Link spans for the given options, valid at a point in a channel; loads the referenced package."
      argument :channel_id, :integer, allow_nil?: false
      argument :at, :utc_datetime, allow_nil?: false
      argument :option_ids, {:array, :integer}, allow_nil?: false

      prepare build(load: [:package])

      filter expr(
               channel_id == ^arg(:channel_id) and
                 option_id in ^arg(:option_ids) and
                 fragment("? @> ?::timestamptz", valid, ^arg(:at))
             )
    end

    read :open_for_packages do
      description "Open (current) link spans for a set of packages across channels; loads the referencing option."
      argument :package_ids, {:array, :integer}, allow_nil?: false

      prepare build(load: [:option])

      filter expr(package_id in ^arg(:package_ids) and fragment("upper_inf(?)", valid))
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

    # Derived from the payload columns, so never one of them. Nil on spans
    # written before the column existed; the engine treats that as changed.
    attribute :fingerprint, :binary

    timestamps()
  end

  relationships do
    belongs_to :channel, Tracker.Nixpkgs.Channel, attribute_type: :integer, allow_nil?: false
    belongs_to :option, Tracker.Nixpkgs.Option, attribute_type: :integer, allow_nil?: false
    belongs_to :package, Tracker.Nixpkgs.Package, attribute_type: :integer, allow_nil?: false
  end

  @doc """
  The `SpanEngine.Spec` driving option↔package link spans: keyed on
  `(option_id, package_id)` within a channel with an empty fingerprint, so a
  span is open exactly while the option references the package. Repointing an
  option at a different package closes the old `package_id` key and opens the
  new one.
  """
  @spec spec() :: Tracker.Nixpkgs.SpanEngine.Spec.t()
  def spec do
    Tracker.Nixpkgs.SpanEngine.Spec.new(
      resource: __MODULE__,
      key_columns: [:option_id, :package_id],
      payload_columns: []
    )
  end
end

defmodule Tracker.Nixpkgs.PackageSpan do
  @moduledoc """
  Validity-interval ("span") of a package's version + metadata within a channel.

  One row per *change*: a span opens when a package first appears (or its
  fingerprint changes) and closes (`valid` upper bound set) when it is removed or
  changes again. Keyed on `(channel_id, package_id)`; overlap is prevented
  per-channel by the `btree_gist` EXCLUDE constraint. Point-in-time reads use
  `channel_id = $c AND valid @> $released_at`; "current" is `upper_inf(valid)`.

  Payload (fingerprint basis) moved off the identity-only `packages` table:
  `version`, `description`, `homepage`, `licenses`, `position`, `package_set`,
  `set_version`.
  """
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "package_spans"
    repo Tracker.Repo

    custom_statements do
      # btree_gist EXCLUDE: no two spans for the same (channel, package) may have
      # overlapping validity. Its backing GiST index also serves point-in-time
      # `valid @> released_at` containment reads.
      statement :package_spans_no_overlap do
        up "ALTER TABLE package_spans ADD CONSTRAINT package_spans_no_overlap EXCLUDE USING gist (channel_id WITH =, package_id WITH =, valid WITH &&)"
        down "ALTER TABLE package_spans DROP CONSTRAINT package_spans_no_overlap"
      end

      # Partial index over open spans for hot current-state browse.
      statement :package_spans_current do
        up "CREATE INDEX package_spans_current ON package_spans (channel_id, package_id) WHERE upper_inf(valid)"
        down "DROP INDEX package_spans_current"
      end
    end
  end

  code_interface do
    define :read
    define :at, args: [:channel_id, :at]
    define :at_for_packages, args: [:channel_id, :at, :package_ids]
    define :by_package, args: [:package_id, {:optional, :channel_id}]
    define :current_for_packages, args: [:channel_id, :package_ids]
  end

  @payload_columns [
    :version,
    :description,
    :homepage,
    :licenses,
    :position,
    :package_set,
    :set_version
  ]

  @doc """
  The `SpanEngine.Spec` driving package metadata spans: keyed on `package_id`
  within a channel, fingerprinted on version + the metadata payload.
  """
  @spec spec() :: Tracker.Nixpkgs.SpanEngine.Spec.t()
  def spec do
    Tracker.Nixpkgs.SpanEngine.Spec.new(
      resource: __MODULE__,
      key_columns: [:package_id],
      payload_columns: @payload_columns
    )
  end

  @doc "The payload (fingerprint) columns carried on each package span."
  @spec payload_columns() :: [atom()]
  def payload_columns, do: @payload_columns

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

    read :at_for_packages do
      description "Spans valid at a point in time for specific packages in a channel."
      argument :channel_id, :integer, allow_nil?: false
      argument :at, :utc_datetime, allow_nil?: false
      argument :package_ids, {:array, :integer}, allow_nil?: false

      filter expr(
               channel_id == ^arg(:channel_id) and
                 package_id in ^arg(:package_ids) and
                 fragment("? @> ?::timestamptz", valid, ^arg(:at))
             )
    end

    read :by_package do
      description "All spans for a package, optionally scoped to one channel."
      argument :package_id, :integer, allow_nil?: false
      argument :channel_id, :integer

      filter expr(
               package_id == ^arg(:package_id) and
                 if not is_nil(^arg(:channel_id)) do
                   channel_id == ^arg(:channel_id)
                 else
                   true
                 end
             )
    end

    read :current_for_packages do
      description "Open (current) spans for a set of packages in a channel."
      argument :channel_id, :integer, allow_nil?: false
      argument :package_ids, {:array, :integer}, allow_nil?: false

      filter expr(
               channel_id == ^arg(:channel_id) and
                 package_id in ^arg(:package_ids) and
                 fragment("upper_inf(?)", valid)
             )
    end

    create :open do
      accept [
        :channel_id,
        :package_id,
        :valid,
        :version,
        :description,
        :homepage,
        :licenses,
        :position,
        :package_set,
        :set_version
      ]
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

    attribute :version, :string, public?: true
    attribute :description, :string, public?: true
    attribute :homepage, {:array, :string}, public?: true
    attribute :licenses, {:array, :string}, public?: true
    attribute :position, :string, public?: true
    attribute :package_set, :string, public?: true
    attribute :set_version, :string, public?: true

    timestamps()
  end

  relationships do
    belongs_to :channel, Tracker.Nixpkgs.Channel, attribute_type: :integer, allow_nil?: false
    belongs_to :package, Tracker.Nixpkgs.Package, attribute_type: :integer, allow_nil?: false
  end
end

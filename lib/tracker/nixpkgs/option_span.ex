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
    define :at, args: [:channel_id, :at]
    define :at_for_options, args: [:channel_id, :at, :option_ids]
    define :by_option, args: [:option_id, {:optional, :channel_id}]
    define :current_for_options, args: [:option_ids]

    define :list_by_channel,
      args: [:channel_id, :at, {:optional, :search}, {:optional, :prefix}]

    define :list_direct_by_prefix, args: [:channel_id, :at, :prefix]
  end

  @payload_columns [
    :description,
    :type,
    :default,
    :example,
    :read_only,
    :loc,
    :related_packages
  ]

  @doc """
  The `SpanEngine.Spec` driving option metadata spans: keyed on `option_id`
  within a channel, fingerprinted on the metadata payload.
  """
  @spec spec() :: Tracker.Nixpkgs.SpanEngine.Spec.t()
  def spec do
    Tracker.Nixpkgs.SpanEngine.Spec.new(
      resource: __MODULE__,
      key_columns: [:option_id],
      payload_columns: @payload_columns
    )
  end

  @doc "The payload (fingerprint) columns carried on each option span."
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

    read :at_for_options do
      description "Spans valid at a point in time for specific options in a channel."
      argument :channel_id, :integer, allow_nil?: false
      argument :at, :utc_datetime, allow_nil?: false
      argument :option_ids, {:array, :integer}, allow_nil?: false

      filter expr(
               channel_id == ^arg(:channel_id) and
                 option_id in ^arg(:option_ids) and
                 fragment("? @> ?::timestamptz", valid, ^arg(:at))
             )
    end

    read :by_option do
      description "All spans for an option, optionally scoped to one channel."
      argument :option_id, :integer, allow_nil?: false
      argument :channel_id, :integer

      filter expr(
               option_id == ^arg(:option_id) and
                 if not is_nil(^arg(:channel_id)) do
                   channel_id == ^arg(:channel_id)
                 else
                   true
                 end
             )
    end

    read :current_for_options do
      description "Open (current) spans for a set of options across channels."
      argument :option_ids, {:array, :integer}, allow_nil?: false

      filter expr(option_id in ^arg(:option_ids) and fragment("upper_inf(?)", valid))
    end

    read :list_by_channel do
      description "Options valid at a point in a channel, fuzzy-ranked, paginated."
      argument :channel_id, :integer, allow_nil?: false
      argument :at, :utc_datetime, allow_nil?: false
      argument :search, :string, default: ""
      argument :prefix, :string, default: ""

      pagination do
        offset? true
        countable true
        default_limit 15
      end

      prepare build(sort: [option_name: :asc], load: [:option])
      prepare Tracker.Nixpkgs.Preparations.OptionSpanSortByRelevance

      filter expr(
               channel_id == ^arg(:channel_id) and
                 fragment("? @> ?::timestamptz", valid, ^arg(:at))
             )

      filter expr(
               if ^arg(:search) != "" do
                 fragment("strict_word_similarity(?, ?) > 0.4", ^arg(:search), option.name) or
                   contains(option.name, ^arg(:search))
               else
                 true
               end
             )

      filter expr(
               if ^arg(:prefix) != "" do
                 option.name == ^arg(:prefix) or
                   fragment("? LIKE ? || '.%'", option.name, ^arg(:prefix))
               else
                 true
               end
             )
    end

    read :list_direct_by_prefix do
      description "The option at the prefix itself plus its direct children, fully loaded for display. An empty prefix returns the depth-1 options."

      argument :channel_id, :integer, allow_nil?: false
      argument :at, :utc_datetime, allow_nil?: false
      argument :prefix, :string, default: ""

      prepare build(sort: [option_name: :asc], load: [option: [:packages]])

      filter expr(
               channel_id == ^arg(:channel_id) and
                 fragment("? @> ?::timestamptz", valid, ^arg(:at)) and
                 if is_nil(^arg(:prefix)) or ^arg(:prefix) == "" do
                   fragment("? NOT LIKE '%.%'", option.name)
                 else
                   option.name == ^arg(:prefix) or
                     (fragment("? LIKE ? || '.%'", option.name, ^arg(:prefix)) and
                        fragment("? NOT LIKE ? || '.%.%'", option.name, ^arg(:prefix)))
                 end
             )
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

  calculations do
    calculate :option_name, :string, expr(option.name)
  end
end

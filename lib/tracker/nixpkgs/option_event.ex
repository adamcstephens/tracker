defmodule Tracker.Nixpkgs.OptionEvent do
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "option_events"
    repo Tracker.Repo
  end

  code_interface do
    define :list
    define :list_by_option, args: [:option_id]
    define :list_between_revisions, args: [:channel_id, :from_date, :to_date]
  end

  actions do
    defaults [:read]

    read :list do
      prepare build(load: [:option, :channel_revision], sort: [{:inserted_at, :desc}])
    end

    create :create do
      accept [:type, :option_id, :channel_revision_id]
    end

    read :list_by_option do
      argument :option_id, :integer do
        allow_nil? false
      end

      prepare build(load: [:channel_revision], sort: [{:inserted_at, :desc}])
      filter expr(option_id == ^arg(:option_id))
    end

    read :list_between_revisions do
      argument :channel_id, :integer do
        allow_nil? false
      end

      argument :from_date, :utc_datetime do
        allow_nil? false
      end

      argument :to_date, :utc_datetime do
        allow_nil? false
      end

      prepare build(load: [:option, :channel_revision], sort: [{:inserted_at, :asc}])

      filter expr(
               channel_revision.channel_id == ^arg(:channel_id) and
                 channel_revision.released_at > ^arg(:from_date) and
                 channel_revision.released_at <= ^arg(:to_date)
             )
    end
  end

  attributes do
    integer_primary_key :id

    attribute :type, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:added, :removed]
    end

    timestamps()
  end

  # 6 columns: id, type, option_id, channel_revision_id, inserted_at, updated_at
  @ash_cols 6
  @max_batch div(65_535, @ash_cols)

  def bulk_create_all(records) do
    records
    |> Stream.chunk_every(@max_batch)
    |> Enum.each(fn chunk ->
      Ash.bulk_create(chunk, __MODULE__, :create,
        batch_size: @max_batch,
        return_errors?: true
      )
    end)
  end

  relationships do
    belongs_to :option, Tracker.Nixpkgs.Option, attribute_type: :integer, allow_nil?: false

    belongs_to :channel_revision, Tracker.Nixpkgs.ChannelRevision,
      attribute_type: :integer,
      allow_nil?: false
  end
end

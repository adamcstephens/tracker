defmodule Tracker.Nixpkgs.PackageEvent do
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "package_events"
    repo Tracker.Repo
  end

  code_interface do
    define :create
    define :list
    define :list_by_package, args: [:package_id, {:optional, :channel_id}]
    define :list_between_revisions, args: [:channel_id, :from_date, :to_date]
    define :list_for_revision_packages, args: [:channel_revision_id, :package_ids]
  end

  actions do
    defaults [:read]

    read :list do
      prepare build(load: [:package, :channel_revision], sort: [{:inserted_at, :desc}])
    end

    create :create do
      accept [:type, :package_id, :channel_revision_id]
    end

    read :list_by_package do
      argument :package_id, :integer do
        allow_nil? false
      end

      argument :channel_id, :integer

      prepare build(load: [:channel_revision], sort: [{:inserted_at, :desc}])

      filter expr(
               package_id == ^arg(:package_id) and
                 if not is_nil(^arg(:channel_id)) do
                   channel_revision.channel_id == ^arg(:channel_id)
                 else
                   true
                 end
             )
    end

    read :list_for_revision_packages do
      description "Added/removed events for a set of packages within one channel revision."

      argument :channel_revision_id, :integer, allow_nil?: false
      argument :package_ids, {:array, :integer}, allow_nil?: false

      filter expr(
               channel_revision_id == ^arg(:channel_revision_id) and
                 package_id in ^arg(:package_ids)
             )
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

      prepare build(load: [:package, :channel_revision], sort: [{:inserted_at, :asc}])

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

  # 6 columns: id, type, package_id, channel_revision_id, inserted_at, updated_at
  @ash_cols 6
  @max_batch div(65_535, @ash_cols)

  def bulk_create_all(records) do
    Tracker.Nixpkgs.BulkCreate.run!(records, __MODULE__, :create, @max_batch)
  end

  relationships do
    belongs_to :package, Tracker.Nixpkgs.Package, attribute_type: :integer, allow_nil?: false

    belongs_to :channel_revision, Tracker.Nixpkgs.ChannelRevision,
      attribute_type: :integer,
      allow_nil?: false
  end
end

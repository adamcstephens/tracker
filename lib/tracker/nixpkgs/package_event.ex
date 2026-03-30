defmodule Tracker.Nixpkgs.PackageEvent do
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "package_events"
    repo Tracker.Repo
  end

  code_interface do
    define :list
    define :list_by_package, args: [:package_id]
    define :list_between_revisions, args: [:channel, :from_date, :to_date]
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

      prepare build(load: [:channel_revision], sort: [{:inserted_at, :desc}])
      filter expr(package_id == ^arg(:package_id))
    end

    read :list_between_revisions do
      argument :channel, :string do
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
               channel_revision.channel == ^arg(:channel) and
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

  relationships do
    belongs_to :package, Tracker.Nixpkgs.Package, attribute_type: :integer, allow_nil?: false

    belongs_to :channel_revision, Tracker.Nixpkgs.ChannelRevision,
      attribute_type: :integer,
      allow_nil?: false
  end
end

defmodule Tracker.Nixpkgs.PackageEvent do
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "package_events"
    repo Tracker.Repo
  end

  code_interface do
    define :list
    define :list_by_package, args: [:package_id]
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

defmodule Tracker.Nixpkgs.Package do
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "packages"
    repo Tracker.Repo
  end

  code_interface do
    define :bulk_upsert, args: [:attribute]
  end

  actions do
    defaults [:read]

    read :list do
      argument :search, :ci_string

      pagination do
        offset? true
        countable true
        default_limit 15
      end

      prepare Tracker.Nixpkgs.Preparations.SortByRelevance

      filter expr(
               if not is_nil(^arg(:search)) and ^arg(:search) != "" do
                 contains(attribute, ^arg(:search))
               else
                 true
               end
             )
    end

    create :create do
      accept [:attribute]
    end

    create :bulk_upsert do
      accept [:attribute, :description, :homepage, :position]
      upsert? true
      upsert_identity :unique_attribute
      upsert_fields [:description, :homepage, :position, :updated_at]
    end
  end

  attributes do
    integer_primary_key :id

    attribute :attribute, :string do
      allow_nil? false
      public? true
    end

    attribute :description, :string, public?: true
    attribute :homepage, :string, public?: true
    attribute :position, :string, public?: true

    timestamps()
  end

  relationships do
    has_many :revisions, Tracker.Nixpkgs.PackageRevision

    many_to_many :maintainers, Tracker.Nixpkgs.Maintainer do
      through Tracker.Nixpkgs.PackageMaintainer
      source_attribute_on_join_resource :package_id
      destination_attribute_on_join_resource :maintainer_id
    end

    many_to_many :teams, Tracker.Nixpkgs.Team do
      through Tracker.Nixpkgs.PackageTeam
      source_attribute_on_join_resource :package_id
      destination_attribute_on_join_resource :team_id
    end
  end

  identities do
    identity :unique_attribute, [:attribute]
  end
end

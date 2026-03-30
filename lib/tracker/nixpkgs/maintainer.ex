defmodule Tracker.Nixpkgs.Maintainer do
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "maintainers"
    repo Tracker.Repo
  end

  code_interface do
    define :read
    define :list, args: [{:optional, :search}]
    define :bulk_upsert
    define :get_by_github, action: :read, get_by: [:github]
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

      prepare build(sort: :name)

      filter expr(
               if not is_nil(^arg(:search)) and ^arg(:search) != "" do
                 contains(name, ^arg(:search)) or contains(github, ^arg(:search))
               else
                 true
               end
             )
    end

    create :bulk_upsert do
      accept [:github_id, :name, :email, :github, :matrix]
      upsert? true
      upsert_identity :unique_github_id
      upsert_fields [:name, :email, :github, :matrix, :updated_at]
    end
  end

  attributes do
    integer_primary_key :id

    attribute :github_id, :integer do
      allow_nil? false
      public? true
    end

    attribute :name, :string, public?: true
    attribute :email, :string, public?: true
    attribute :github, :string, public?: true
    attribute :matrix, :string, public?: true

    timestamps()
  end

  relationships do
    many_to_many :packages, Tracker.Nixpkgs.Package do
      through Tracker.Nixpkgs.PackageMaintainer
      source_attribute_on_join_resource :maintainer_id
      destination_attribute_on_join_resource :package_id
    end

    many_to_many :teams, Tracker.Nixpkgs.Team do
      through Tracker.Nixpkgs.TeamMember
      source_attribute_on_join_resource :maintainer_id
      destination_attribute_on_join_resource :team_id
    end
  end

  identities do
    identity :unique_github_id, [:github_id]
    identity :unique_github, [:github]
  end
end

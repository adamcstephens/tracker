defmodule Tracker.Nixpkgs.Team do
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "teams"
    repo Tracker.Repo
  end

  code_interface do
    define :read
    define :list, args: [{:optional, :search}, {:optional, :channel_id}]
    define :bulk_upsert
    define :get_by_short_name, action: :read, get_by: [:short_name]
    define :id_map, action: :id_map
  end

  actions do
    defaults [:read]

    read :id_map do
      prepare build(select: [:short_name])
    end

    read :list do
      argument :search, :ci_string
      argument :channel_id, :integer

      pagination do
        offset? true
        countable true
        default_limit 15
      end

      prepare build(sort: :short_name)

      filter expr(
               if not is_nil(^arg(:search)) and ^arg(:search) != "" do
                 contains(short_name, ^arg(:search)) or contains(scope, ^arg(:search))
               else
                 true
               end
             )
    end

    create :bulk_upsert do
      accept [:short_name, :scope, :github, :github_id]
      upsert? true
      upsert_identity :unique_short_name
      upsert_fields [:scope, :github, :github_id, :updated_at]
    end
  end

  attributes do
    integer_primary_key :id

    attribute :short_name, :ci_string do
      allow_nil? false
      public? true
    end

    attribute :scope, :string, public?: true
    attribute :github, :string, public?: true
    attribute :github_id, :integer, public?: true

    timestamps()
  end

  relationships do
    many_to_many :members, Tracker.Nixpkgs.Maintainer do
      through Tracker.Nixpkgs.TeamMember
      source_attribute_on_join_resource :team_id
      destination_attribute_on_join_resource :maintainer_id
    end

    many_to_many :packages, Tracker.Nixpkgs.Package do
      through Tracker.Nixpkgs.PackageTeam
      source_attribute_on_join_resource :team_id
      destination_attribute_on_join_resource :package_id
    end
  end

  # 7 columns: id, short_name, scope, github, github_id, inserted_at, updated_at
  @ash_cols 7
  @max_batch div(65_535, @ash_cols)

  def bulk_upsert_all(records) do
    records
    |> Stream.chunk_every(@max_batch)
    |> Enum.each(fn chunk ->
      Ash.bulk_create(chunk, __MODULE__, :bulk_upsert,
        batch_size: @max_batch,
        return_errors?: true
      )
    end)
  end

  identities do
    identity :unique_short_name, [:short_name]
  end
end

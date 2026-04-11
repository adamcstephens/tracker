defmodule Tracker.Nixpkgs.Maintainer do
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "maintainers"
    repo Tracker.Repo
  end

  code_interface do
    define :read
    define :list, args: [{:optional, :search}, {:optional, :channel_id}]
    define :bulk_upsert
    define :get_by_github, action: :read, get_by: [:github]
    define :get_by_github_id, action: :read, get_by: [:github_id]
    define :id_map, action: :id_map
  end

  actions do
    defaults [:read]

    read :id_map do
      prepare build(select: [:github_id])
    end

    read :list do
      argument :search, :ci_string
      argument :channel_id, :integer

      pagination do
        offset? true
        countable true
        default_limit 15
      end

      prepare build(sort: :github)

      filter expr(
               if not is_nil(^arg(:search)) and ^arg(:search) != "" do
                 contains(github, ^arg(:search))
               else
                 true
               end and
                 if not is_nil(^arg(:channel_id)) do
                   exists(
                     packages,
                     exists(revisions, channel_revision.channel_id == ^arg(:channel_id))
                   )
                 else
                   true
                 end
             )
    end

    create :bulk_upsert do
      accept [:github_id, :github]
      upsert? true
      upsert_identity :unique_github_id
      upsert_fields [:github, :updated_at]
    end
  end

  attributes do
    integer_primary_key :id

    attribute :github_id, :integer do
      allow_nil? false
      public? true
    end

    attribute :github, :string, public?: true

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

  # 5 columns: id, github_id, github, inserted_at, updated_at
  @ash_cols 5
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
    identity :unique_github_id, [:github_id]
    identity :unique_github, [:github]
  end
end

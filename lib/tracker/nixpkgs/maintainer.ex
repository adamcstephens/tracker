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
    define :get_by_github_id, action: :read, get_by: [:github_id]
    define :id_map, action: :id_map
    define :by_githubs, args: [:githubs]
    define :reassign_github_id
  end

  actions do
    defaults [:read]

    read :id_map do
      prepare build(select: [:github_id])
    end

    read :list do
      argument :search, :ci_string

      pagination do
        offset? true
        countable true
        default_limit 15
      end

      prepare build(sort: :github)

      filter expr(
               if not is_nil(^arg(:search)) and ^arg(:search) != "" do
                 fragment("strict_word_similarity(?, ?) > 0.4", ^arg(:search), github) or
                   contains(github, ^arg(:search))
               else
                 true
               end
             )
    end

    read :by_githubs do
      argument :githubs, {:array, :string}, allow_nil?: false
      filter expr(github in ^arg(:githubs))
    end

    create :bulk_upsert do
      accept [:github_id, :github]
      upsert? true
      upsert_identity :unique_github_id
      upsert_fields [:github, :updated_at]
    end

    update :reassign_github_id do
      accept [:github_id]
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
    reconcile_moved_handles(records)
    Tracker.Nixpkgs.BulkCreate.run!(records, __MODULE__, :bulk_upsert, @max_batch)
  end

  # The `:bulk_upsert` action keys on `github_id`, but a github handle can move to
  # a different `github_id` (e.g. nixpkgs correcting a maintainer's githubId). The
  # incoming row would then collide with the stale holder on the `unique_github`
  # identity, which an ON CONFLICT (github_id) upsert cannot absorb — aborting the
  # whole batch. Give each handle to its current github_id before upserting by
  # reassigning the stale row's id in place: a correction that preserves the PK
  # and its FK links, leaving no duplicate handle for the upsert to trip on.
  defp reconcile_moved_handles(records) do
    desired =
      for r <- records,
          handle = r[:github],
          id = r[:github_id],
          handle && id,
          into: %{},
          do: {handle, id}

    desired
    |> Map.keys()
    |> by_githubs!()
    |> Enum.each(fn m ->
      target = desired[m.github]
      if target != m.github_id, do: reassign_github_id!(m, %{github_id: target})
    end)
  end

  identities do
    identity :unique_github_id, [:github_id]
    identity :unique_github, [:github]
  end
end

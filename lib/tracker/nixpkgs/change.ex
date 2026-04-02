defmodule Tracker.Nixpkgs.Change do
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "changes"
    repo Tracker.Repo
  end

  code_interface do
    define :read
    define :list, args: [{:optional, :search}, {:optional, :base_ref}]
    define :get_by_number, action: :read, get_by: [:number]
    define :by_package, args: [:package_id]
    define :by_maintainer_github_id, args: [:github_id]
    define :update_package_count
    define :update_processing_status
    define :bulk_upsert, args: [:number]
    define :distinct_base_refs
    define :existing_numbers, args: [:numbers]
  end

  actions do
    defaults [:read]

    read :list do
      argument :search, :ci_string
      argument :base_ref, :string

      pagination do
        offset? true
        countable true
        default_limit 15
      end

      filter expr(
               if not is_nil(^arg(:search)) and ^arg(:search) != "" do
                 contains(title, ^arg(:search)) or contains(author, ^arg(:search))
               else
                 true
               end and
                 if not is_nil(^arg(:base_ref)) and ^arg(:base_ref) != "" do
                   base_ref == ^arg(:base_ref)
                 else
                   true
                 end
             )
    end

    read :by_package do
      argument :package_id, :integer, allow_nil?: false

      pagination do
        offset? true
        countable true
        default_limit 10
      end

      prepare build(sort: [number: :desc])
      filter expr(exists(change_packages, package_id == ^arg(:package_id)))
    end

    read :by_maintainer_github_id do
      argument :github_id, :integer, allow_nil?: false

      pagination do
        offset? true
        countable true
        default_limit 15
      end

      prepare build(sort: [number: :desc])
      filter expr(author_github_id == ^arg(:github_id) or merged_by_github_id == ^arg(:github_id))
    end

    update :update_package_count do
      accept [:package_count]
    end

    update :update_processing_status do
      accept [:processing_status]
    end

    read :distinct_base_refs do
      prepare build(distinct: [:base_ref], select: [:base_ref], sort: [:base_ref])
    end

    read :existing_numbers do
      argument :numbers, {:array, :integer}, allow_nil?: false

      prepare build(select: [:number])
      filter expr(number in ^arg(:numbers))
    end

    create :bulk_upsert do
      accept [
        :number,
        :title,
        :state,
        :author,
        :author_github_id,
        :merged_by_github_id,
        :url,
        :base_ref,
        :labels,
        :gh_created_at,
        :merged_at,
        :merge_commit_sha,
        :processing_status
      ]

      upsert? true
      upsert_identity :unique_number

      upsert_fields [
        :title,
        :state,
        :author,
        :author_github_id,
        :merged_by_github_id,
        :url,
        :base_ref,
        :labels,
        :gh_created_at,
        :merged_at,
        :merge_commit_sha,
        :processing_status,
        :updated_at
      ]
    end
  end

  attributes do
    integer_primary_key :id

    attribute :number, :integer do
      allow_nil? false
      public? true
    end

    attribute :title, :string do
      allow_nil? false
      public? true
    end

    attribute :state, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:open, :closed, :merged]
    end

    attribute :author, :string, public?: true
    attribute :author_github_id, :integer, public?: true
    attribute :merged_by_github_id, :integer, public?: true
    attribute :url, :string, public?: true
    attribute :base_ref, :string, public?: true
    attribute :labels, {:array, :string}, public?: true
    attribute :gh_created_at, :utc_datetime, public?: true
    attribute :merged_at, :utc_datetime, public?: true
    attribute :merge_commit_sha, :string, public?: true
    attribute :package_count, :integer, public?: true, default: 0

    attribute :processing_status, :atom,
      public?: true,
      default: :pending,
      constraints: [
        one_of: [
          :pending,
          :processed,
          :artifact_expired,
          :no_workflow_run,
          :no_comparison_artifact,
          :failed
        ]
      ]

    timestamps()
  end

  relationships do
    has_many :change_packages, Tracker.Nixpkgs.ChangePackage
    has_many :change_channels, Tracker.Nixpkgs.ChangeChannel

    many_to_many :packages, Tracker.Nixpkgs.Package do
      through Tracker.Nixpkgs.ChangePackage
      source_attribute_on_join_resource :change_id
      destination_attribute_on_join_resource :package_id
    end
  end

  identities do
    identity :unique_number, [:number]
  end

  # 15 columns: number, title, state, author, author_github_id, merged_by_github_id,
  # url, base_ref, labels, gh_created_at, merged_at, merge_commit_sha, processing_status,
  # inserted_at, updated_at
  @insert_cols 15
  @max_rows div(65_535, @insert_cols)

  @doc """
  Bulk upsert changes using raw Ecto insert_all for performance.

  Returns a map of number => id.
  """
  def bulk_upsert_all(records) do
    now = DateTime.utc_now(:second)

    records
    |> Stream.map(fn record ->
      record
      |> Map.put(:inserted_at, now)
      |> Map.put(:updated_at, now)
      |> Map.update(:state, :open, &to_string/1)
      |> Map.update(:processing_status, "pending", &to_string/1)
    end)
    |> Stream.chunk_every(@max_rows)
    |> Enum.reduce(%{}, fn chunk, acc ->
      {_count, rows} =
        Tracker.Repo.insert_all(
          "changes",
          chunk,
          on_conflict:
            {:replace,
             [
               :title,
               :state,
               :author,
               :author_github_id,
               :merged_by_github_id,
               :url,
               :base_ref,
               :labels,
               :gh_created_at,
               :merged_at,
               :merge_commit_sha,
               :processing_status,
               :updated_at
             ]},
          conflict_target: :number,
          returning: [:id, :number]
        )

      Map.merge(acc, Map.new(rows, fn %{id: id, number: number} -> {number, id} end))
    end)
  end
end

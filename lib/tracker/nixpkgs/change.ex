defmodule Tracker.Nixpkgs.Change do
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "changes"
    repo Tracker.Repo
  end

  code_interface do
    define :read
    define :list, args: [{:optional, :search}]
    define :bulk_upsert, args: [:number]
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

      prepare build(sort: [number: :desc])

      filter expr(
               if not is_nil(^arg(:search)) and ^arg(:search) != "" do
                 contains(title, ^arg(:search))
               else
                 true
               end
             )
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
        :merge_commit_sha
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

  # 14 columns: number, title, state, author, author_github_id, merged_by_github_id,
  # url, base_ref, labels, gh_created_at, merged_at, merge_commit_sha, inserted_at, updated_at
  @insert_cols 14
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
               :updated_at
             ]},
          conflict_target: :number,
          returning: [:id, :number]
        )

      Map.merge(acc, Map.new(rows, fn %{id: id, number: number} -> {number, id} end))
    end)
  end
end

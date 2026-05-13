defmodule Tracker.Nixpkgs.Change do
  use Ash.Resource,
    otp_app: :tracker,
    domain: Tracker.Nixpkgs,
    data_layer: AshPostgres.DataLayer,
    notifiers: [Ash.Notifier.PubSub]

  postgres do
    table "changes"
    repo Tracker.Repo
  end

  code_interface do
    define :read
    define :list, args: [{:optional, :search}, {:optional, :base_ref}, {:optional, :channel_name}]
    define :get_by_number, action: :read, get_by: [:number]
    define :get_by_node_id, action: :read, get_by: [:node_id]
    define :by_package, args: [:package_id]
    define :by_files, args: [:file_ids, {:optional, :limit}]
    define :by_maintainer_github_id, args: [:github_id, {:optional, :channel_name}]
    define :update_package_count
    define :update_processing_status
    define :set_files_over_limit
    define :set_node_id
    define :list_missing_node_ids
    define :bulk_upsert, args: [:number]
    define :distinct_base_refs
    define :preexisting_for_diff, args: [:numbers]
    define :max_gh_updated_at
    define :max_number
    define :numbers_in_range, args: [:lo, :hi]
    define :stalest_unfinished
    define :pending_merged_backlog
    define :in_flight_propagation
    define :for_channel_link, args: [:branch_name]
    define :updated_since, args: [:since, {:optional, :states}]
    define :refresh_from_graphql
    define :touch_last_checked
    define :mark_dormant
    define :mark_not_found
  end

  actions do
    defaults [:read]

    read :list do
      argument :search, :ci_string
      argument :base_ref, :string
      argument :channel_name, :string

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
                 end and
                 if not is_nil(^arg(:channel_name)) do
                   exists(change_branches, branch_name == ^arg(:channel_name))
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

    read :by_files do
      argument :file_ids, {:array, :integer}, allow_nil?: false
      argument :limit, :integer, default: 10

      prepare fn query, _ctx ->
        limit = Ash.Query.get_argument(query, :limit)
        Ash.Query.limit(query, limit)
      end

      prepare build(sort: [gh_updated_at: :desc_nils_last])
      filter expr(exists(change_files, file_id in ^arg(:file_ids)))
    end

    read :by_maintainer_github_id do
      argument :github_id, :integer, allow_nil?: false
      argument :channel_name, :string

      pagination do
        offset? true
        countable true
        default_limit 15
      end

      prepare build(sort: [number: :desc])

      filter expr(
               (author_github_id == ^arg(:github_id) or merged_by_github_id == ^arg(:github_id)) and
                 if not is_nil(^arg(:channel_name)) do
                   exists(change_branches, branch_name == ^arg(:channel_name))
                 else
                   true
                 end
             )
    end

    update :update_package_count do
      accept [:package_count]
    end

    update :update_processing_status do
      accept [:processing_status]
    end

    update :set_files_over_limit do
      accept [:files_over_limit]
    end

    update :set_node_id do
      accept [:node_id]
    end

    update :refresh_from_graphql do
      accept [
        :state,
        :base_ref,
        :head_ref,
        :head_sha,
        :title,
        :labels,
        :gh_updated_at,
        :closed_at,
        :merged_at,
        :merge_commit_sha
      ]

      change set_attribute(:last_checked_at, &DateTime.utc_now/0)
    end

    update :touch_last_checked do
      change set_attribute(:last_checked_at, &DateTime.utc_now/0)
    end

    update :mark_dormant do
      accept []
      change set_attribute(:polling_status, :dormant)
    end

    update :mark_not_found do
      accept []
      change set_attribute(:polling_status, :not_found)
    end

    read :stalest_unfinished do
      prepare build(
                sort: [last_checked_at: :asc_nils_first],
                limit: 100
              )

      filter expr(state in [:draft, :open] and not is_nil(node_id) and polling_status == :active)
    end

    read :pending_merged_backlog do
      prepare build(sort: [merged_at: :asc_nils_first], limit: 50)

      filter expr(state == :merged and processing_status == :pending)
    end

    read :in_flight_propagation do
      prepare build(sort: [merged_at: :desc_nils_last], load: [:change_branches])

      filter expr(
               state == :merged and
                 not is_nil(merge_commit_sha) and
                 not is_nil(base_ref)
             )
    end

    read :for_channel_link do
      argument :branch_name, :string, allow_nil?: false

      filter expr(
               state == :merged and
                 not is_nil(merge_commit_sha) and
                 not exists(
                   change_branches,
                   branch_name == ^arg(:branch_name) and not is_nil(channel_revision_id)
                 )
             )
    end

    read :updated_since do
      argument :since, :utc_datetime, allow_nil?: false
      argument :states, {:array, :atom}, default: [:open, :draft, :merged]

      prepare build(select: [:number, :state], sort: [gh_updated_at: :asc])
      filter expr(gh_updated_at >= ^arg(:since) and state in ^arg(:states))
    end

    read :list_missing_node_ids do
      pagination do
        offset? true
        countable true
        default_limit 100
      end

      prepare build(sort: [number: :asc])
      filter expr(is_nil(node_id))
    end

    read :distinct_base_refs do
      prepare build(distinct: [:base_ref], select: [:base_ref], sort: [:base_ref])
    end

    read :preexisting_for_diff do
      argument :numbers, {:array, :integer}, allow_nil?: false

      prepare build(select: [:id, :number, :state, :head_sha, :base_ref, :polling_status])
      filter expr(number in ^arg(:numbers))
    end

    action :max_gh_updated_at, :utc_datetime do
      allow_nil? true

      run fn _input, _context ->
        Ash.max(__MODULE__, :gh_updated_at)
      end
    end

    action :max_number, :integer do
      allow_nil? true

      run fn _input, _context ->
        Ash.max(__MODULE__, :number)
      end
    end

    read :numbers_in_range do
      argument :lo, :integer, allow_nil?: false
      argument :hi, :integer, allow_nil?: false

      prepare build(select: [:number])
      filter expr(number >= ^arg(:lo) and number <= ^arg(:hi))
    end

    create :bulk_upsert do
      accept [
        :number,
        :node_id,
        :title,
        :state,
        :author,
        :author_github_id,
        :merged_by_github_id,
        :url,
        :base_ref,
        :head_ref,
        :head_sha,
        :labels,
        :gh_created_at,
        :gh_updated_at,
        :last_checked_at,
        :closed_at,
        :merged_at,
        :merge_commit_sha,
        :processing_status
      ]

      upsert? true
      upsert_identity :unique_number

      upsert_fields [
        :node_id,
        :title,
        :state,
        :author,
        :author_github_id,
        :merged_by_github_id,
        :url,
        :base_ref,
        :head_ref,
        :head_sha,
        :labels,
        :gh_created_at,
        :gh_updated_at,
        :last_checked_at,
        :closed_at,
        :merged_at,
        :merge_commit_sha,
        :processing_status,
        :updated_at
      ]
    end
  end

  pub_sub do
    module Phoenix.PubSub
    name Tracker.PubSub
    prefix "changes"

    publish :update_processing_status, "updated"
    publish :refresh_from_graphql, "updated"
  end

  attributes do
    integer_primary_key :id

    attribute :number, :integer do
      allow_nil? false
      public? true
    end

    attribute :node_id, :string, public?: true

    attribute :title, :string do
      allow_nil? false
      public? true
    end

    attribute :state, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:draft, :open, :closed, :merged]
    end

    attribute :author, :string, public?: true
    attribute :author_github_id, :integer, public?: true
    attribute :merged_by_github_id, :integer, public?: true
    attribute :url, :string, public?: true
    attribute :base_ref, :string, public?: true
    attribute :head_ref, :string, public?: true
    attribute :head_sha, :string, public?: true
    attribute :labels, {:array, :string}, public?: true
    attribute :gh_created_at, :utc_datetime, public?: true
    attribute :gh_updated_at, :utc_datetime, public?: true
    attribute :last_checked_at, :utc_datetime_usec, public?: true
    attribute :closed_at, :utc_datetime, public?: true
    attribute :merged_at, :utc_datetime, public?: true
    attribute :merge_commit_sha, :string, public?: true
    attribute :package_count, :integer, public?: true, default: 0

    attribute :files_over_limit, :boolean do
      allow_nil? false
      public? true
      default false
    end

    attribute :processing_status, :atom,
      public?: true,
      default: :pending,
      constraints: [
        one_of: [
          :pending,
          :processed,
          :too_large,
          :base_ref_skipped,
          :artifact_expired,
          :no_workflow_run,
          :no_comparison_artifact,
          :failed
        ]
      ]

    attribute :polling_status, :atom,
      allow_nil?: false,
      public?: true,
      default: :active,
      constraints: [one_of: [:active, :dormant, :not_found]]

    timestamps()
  end

  relationships do
    has_many :change_packages, Tracker.Nixpkgs.ChangePackage
    has_many :change_branches, Tracker.Nixpkgs.ChangeBranch
    has_many :change_files, Tracker.Nixpkgs.ChangeFile

    many_to_many :packages, Tracker.Nixpkgs.Package do
      through Tracker.Nixpkgs.ChangePackage
      source_attribute_on_join_resource :change_id
      destination_attribute_on_join_resource :package_id
    end

    many_to_many :files, Tracker.Nixpkgs.File do
      through Tracker.Nixpkgs.ChangeFile
      source_attribute_on_join_resource :change_id
      destination_attribute_on_join_resource :file_id
    end
  end

  identities do
    identity :unique_number, [:number]
    identity :unique_node_id, [:node_id], nils_distinct?: true
  end

  # 22 columns: number, node_id, title, state, author, author_github_id, merged_by_github_id,
  # url, base_ref, head_ref, head_sha, labels, gh_created_at, gh_updated_at, last_checked_at,
  # closed_at, merged_at, merge_commit_sha, processing_status, polling_status,
  # inserted_at, updated_at
  @insert_cols 22
  @max_rows div(65_535, @insert_cols)

  @doc """
  Marks every active, non-terminal Change whose `gh_updated_at` predates the
  given cutoff as `polling_status: :dormant`. Used by `ChangeRefreshWorker`
  to drop GitHub-side-quiet PRs out of the polling rotation; discovery will
  flip them back to `:active` if they show up again.
  """
  def mark_stale_dormant!(%DateTime{} = cutoff) do
    require Ash.Query

    __MODULE__
    |> Ash.Query.filter(
      state in [:draft, :open] and polling_status == :active and
        not is_nil(gh_updated_at) and gh_updated_at < ^cutoff
    )
    |> Ash.bulk_update!(:mark_dormant, %{}, strategy: :atomic, return_errors?: true)

    :ok
  end

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
      |> Map.put_new(:processing_status, "pending")
      |> Map.update!(:processing_status, &to_string/1)
      |> Map.put(:polling_status, "active")
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
               :node_id,
               :title,
               :state,
               :author,
               :author_github_id,
               :merged_by_github_id,
               :url,
               :base_ref,
               :head_ref,
               :head_sha,
               :labels,
               :gh_created_at,
               :gh_updated_at,
               :last_checked_at,
               :closed_at,
               :merged_at,
               :merge_commit_sha,
               :polling_status,
               :updated_at
             ]},
          conflict_target: :number,
          returning: [:id, :number]
        )

      Map.merge(acc, Map.new(rows, fn %{id: id, number: number} -> {number, id} end))
    end)
  end
end

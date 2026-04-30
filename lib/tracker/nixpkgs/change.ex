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
    define :list, args: [{:optional, :search}, {:optional, :base_ref}, {:optional, :channel_id}]
    define :get_by_number, action: :read, get_by: [:number]
    define :get_by_node_id, action: :read, get_by: [:node_id]
    define :by_package, args: [:package_id]
    define :by_maintainer_github_id, args: [:github_id, {:optional, :channel_id}]
    define :update_package_count
    define :update_changed_files
    define :update_processing_status
    define :set_node_id
    define :list_missing_node_ids
    define :bulk_upsert, args: [:number]
    define :distinct_base_refs
    define :existing_numbers, args: [:numbers]
    define :max_gh_updated_at
    define :stalest_unfinished
    define :pending_merged_backlog
    define :updated_since, args: [:since, {:optional, :states}]
    define :refresh_from_graphql
    define :touch_last_checked
  end

  actions do
    defaults [:read]

    read :list do
      argument :search, :ci_string
      argument :base_ref, :string
      argument :channel_id, :integer

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
                 if not is_nil(^arg(:channel_id)) do
                   exists(change_channels, channel_id == ^arg(:channel_id))
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
      argument :channel_id, :integer

      pagination do
        offset? true
        countable true
        default_limit 15
      end

      prepare build(sort: [number: :desc])

      filter expr(
               (author_github_id == ^arg(:github_id) or merged_by_github_id == ^arg(:github_id)) and
                 if not is_nil(^arg(:channel_id)) do
                   exists(change_channels, channel_id == ^arg(:channel_id))
                 else
                   true
                 end
             )
    end

    update :update_package_count do
      accept [:package_count]
    end

    update :update_changed_files do
      accept [:changed_files]
    end

    update :update_processing_status do
      accept [:processing_status]
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

    read :stalest_unfinished do
      prepare build(
                sort: [last_checked_at: :asc_nils_first],
                limit: 100
              )

      filter expr(state in [:draft, :open] and not is_nil(node_id))
    end

    read :pending_merged_backlog do
      prepare build(sort: [merged_at: :asc_nils_first], limit: 50)

      filter expr(state == :merged and processing_status == :pending)
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

    read :existing_numbers do
      argument :numbers, {:array, :integer}, allow_nil?: false

      prepare build(select: [:number])
      filter expr(number in ^arg(:numbers))
    end

    action :max_gh_updated_at, :utc_datetime do
      allow_nil? true

      run fn _input, _context ->
        Ash.max(__MODULE__, :gh_updated_at)
      end
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

    attribute :changed_files, {:array, :string} do
      public? true
      allow_nil? false
      default []
    end

    attribute :processing_status, :atom,
      public?: true,
      default: :pending,
      constraints: [
        one_of: [
          :pending,
          :processed,
          :too_large,
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
    identity :unique_node_id, [:node_id], nils_distinct?: true
  end

  # 21 columns: number, node_id, title, state, author, author_github_id, merged_by_github_id,
  # url, base_ref, head_ref, head_sha, labels, gh_created_at, gh_updated_at, last_checked_at,
  # closed_at, merged_at, merge_commit_sha, processing_status, inserted_at, updated_at
  @insert_cols 21
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
      |> Map.put_new(:processing_status, "pending")
      |> Map.update!(:processing_status, &to_string/1)
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
               :updated_at
             ]},
          conflict_target: :number,
          returning: [:id, :number]
        )

      Map.merge(acc, Map.new(rows, fn %{id: id, number: number} -> {number, id} end))
    end)
  end
end

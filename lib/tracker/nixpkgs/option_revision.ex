defmodule Tracker.Nixpkgs.OptionRevision do
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "option_revisions"
    repo Tracker.Repo
  end

  code_interface do
    define :read
    define :load
    define :latest_by_option_ids, args: [:option_ids]
    define :list_by_channel_revision, args: [:channel_revision_id, {:optional, :search}]
    define :list_by_channel_revision_and_prefix, args: [:channel_revision_id, :prefix]
    define :list_by_change_and_channel_revision, args: [:change_id, :channel_revision_id]
  end

  actions do
    defaults [:read]

    read :list_by_channel_revision do
      argument :channel_revision_id, :integer, allow_nil?: false
      argument :search, :string, default: ""

      pagination do
        offset? true
        countable true
        default_limit 15
      end

      prepare build(sort: [option_name: :asc], load: [:option])

      filter expr(channel_revision_id == ^arg(:channel_revision_id))

      filter expr(
               if ^arg(:search) != "" do
                 contains(option.name, ^arg(:search))
               else
                 true
               end
             )
    end

    read :list_by_channel_revision_and_prefix do
      argument :channel_revision_id, :integer, allow_nil?: false
      argument :prefix, :string, allow_nil?: false

      prepare build(sort: [option_name: :asc], load: [option: [:packages], files: []])

      filter expr(
               channel_revision_id == ^arg(:channel_revision_id) and
                 (option.name == ^arg(:prefix) or
                    fragment("? LIKE ? || '.%'", option.name, ^arg(:prefix)))
             )
    end

    read :latest_by_option_ids do
      argument :option_ids, {:array, :integer}, allow_nil?: false

      filter expr(option_id in ^arg(:option_ids))

      prepare build(sort: [option_id: :asc, released_at: :desc], distinct: [:option_id])
    end

    read :list_by_change_and_channel_revision do
      argument :change_id, :integer, allow_nil?: false
      argument :channel_revision_id, :integer, allow_nil?: false

      prepare build(sort: [option_name: :asc], load: [:option])

      filter expr(
               channel_revision_id == ^arg(:channel_revision_id) and
                 exists(
                   option_revision_files,
                   exists(file.change_files, change_id == ^arg(:change_id))
                 )
             )
    end

    create :load do
      accept [
        :option_id,
        :channel_revision_id,
        :description,
        :type,
        :default,
        :example,
        :read_only,
        :loc,
        :declarations,
        :related_packages
      ]

      upsert? true
      upsert_identity :unique_option_revision

      upsert_fields [
        :description,
        :type,
        :default,
        :example,
        :read_only,
        :loc,
        :declarations,
        :related_packages,
        :updated_at
      ]
    end
  end

  attributes do
    integer_primary_key :id

    attribute :description, :string, public?: true
    attribute :type, :string, public?: true
    attribute :default, :string, public?: true
    attribute :example, :string, public?: true

    attribute :read_only, :boolean do
      default false
      public? true
    end

    attribute :loc, {:array, :string}, public?: true
    attribute :declarations, {:array, :string}, public?: true
    attribute :related_packages, :string, public?: true

    timestamps()
  end

  relationships do
    belongs_to :option, Tracker.Nixpkgs.Option, attribute_type: :integer, allow_nil?: false

    belongs_to :channel_revision, Tracker.Nixpkgs.ChannelRevision,
      attribute_type: :integer,
      allow_nil?: false

    has_many :option_revision_files, Tracker.Nixpkgs.OptionRevisionFile

    many_to_many :files, Tracker.Nixpkgs.File do
      through Tracker.Nixpkgs.OptionRevisionFile
      source_attribute_on_join_resource :option_revision_id
      destination_attribute_on_join_resource :file_id
    end
  end

  calculations do
    calculate :released_at, :utc_datetime, expr(channel_revision.released_at)
    calculate :option_name, :string, expr(option.name)
  end

  identities do
    identity :unique_option_revision, [:channel_revision_id, :option_id]
  end

  # 12 columns: option_id, channel_revision_id, description, type, default, example,
  #             read_only, loc, declarations, related_packages, inserted_at, updated_at
  @insert_cols 12
  @max_rows div(65_535, @insert_cols)

  @doc """
  Computes the set difference of option_ids between two channel revisions.

  Returns `{added_ids, removed_ids}`.
  """
  def diff_option_ids(new_id, prev_id) do
    {:ok, %{rows: rows}} =
      Tracker.Repo.query(
        """
        SELECT option_id, 'added' AS type FROM (
          SELECT option_id FROM option_revisions WHERE channel_revision_id = $1
          EXCEPT
          SELECT option_id FROM option_revisions WHERE channel_revision_id = $2
        ) added
        UNION ALL
        SELECT option_id, 'removed' AS type FROM (
          SELECT option_id FROM option_revisions WHERE channel_revision_id = $2
          EXCEPT
          SELECT option_id FROM option_revisions WHERE channel_revision_id = $1
        ) removed
        """,
        [new_id, prev_id]
      )

    Enum.split_with(rows, fn [_, type] -> type == "added" end)
    |> then(fn {added, removed} ->
      {Enum.map(added, &hd/1), Enum.map(removed, &hd/1)}
    end)
  end

  @doc """
  Bulk upserts option revisions, returning a map of `option_id => option_revision_id`
  scoped to the records inserted/updated.
  """
  def bulk_insert_all(records) do
    now = DateTime.utc_now(:second)

    records
    |> Stream.map(fn record ->
      record
      |> Map.put(:inserted_at, now)
      |> Map.put(:updated_at, now)
    end)
    |> Stream.chunk_every(@max_rows)
    |> Enum.reduce(%{}, fn chunk, acc ->
      {_count, rows} =
        Tracker.Repo.insert_all(
          "option_revisions",
          chunk,
          on_conflict:
            {:replace,
             [
               :description,
               :type,
               :default,
               :example,
               :read_only,
               :loc,
               :declarations,
               :related_packages,
               :updated_at
             ]},
          conflict_target: [:channel_revision_id, :option_id],
          returning: [:id, :option_id]
        )

      Map.merge(acc, Map.new(rows, fn %{id: id, option_id: oid} -> {oid, id} end))
    end)
  end
end

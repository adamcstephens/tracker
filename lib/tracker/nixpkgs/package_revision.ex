defmodule Tracker.Nixpkgs.PackageRevision do
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "package_revisions"
    repo Tracker.Repo
  end

  code_interface do
    define :read
    define :list_by_package, args: [:package_id, {:optional, :channel}, {:optional, :version}]
    define :version_changes_by_package, args: [:package_id]
    define :load
  end

  actions do
    defaults [:read, create: [:version]]

    read :list_by_package do
      argument :package_id, :integer do
        allow_nil? false
      end

      argument :channel, :string
      argument :version, :string

      pagination do
        offset? true
        countable true
        default_limit 15
      end

      prepare build(load: [:channel_revision])

      filter expr(
               package_id == ^arg(:package_id) and
                 if not is_nil(^arg(:channel)) and ^arg(:channel) != "" do
                   channel_revision.channel == ^arg(:channel)
                 else
                   true
                 end and
                 if not is_nil(^arg(:version)) and ^arg(:version) != "" do
                   contains(version, ^arg(:version))
                 else
                   true
                 end
             )
    end

    read :version_changes_by_package do
      argument :package_id, :integer do
        allow_nil? false
      end

      prepare build(load: [:channel_revision], sort: [released_at: :asc])
      filter expr(package_id == ^arg(:package_id))
    end

    create :load do
      accept [:version, :channel_revision_id, :package_id]
      upsert? true
      upsert_identity :unique_package_revision
      upsert_fields [:version, :updated_at]
    end
  end

  attributes do
    integer_primary_key :id

    attribute :version, :string do
      allow_nil? false
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :package, Tracker.Nixpkgs.Package, attribute_type: :integer, allow_nil?: false

    belongs_to :channel_revision, Tracker.Nixpkgs.ChannelRevision,
      attribute_type: :integer,
      allow_nil?: false
  end

  calculations do
    calculate :channel, :string, expr(channel_revision.channel)
    calculate :revision_hash, :string, expr(channel_revision.revision)
    calculate :released_at, :utc_datetime, expr(channel_revision.released_at)
  end

  identities do
    identity :unique_package_revision, [:channel_revision_id, :package_id]
  end

  # 5 columns: package_id, channel_revision_id, version, inserted_at, updated_at
  @insert_cols 5
  @max_rows div(65_535, @insert_cols)

  @doc """
  Computes the set difference of package_ids between two channel revisions.

  Returns `{added_ids, removed_ids}` where:
  - `added_ids` are package_ids present in `new_id` but not `prev_id`
  - `removed_ids` are package_ids present in `prev_id` but not `new_id`

  Uses SQL EXCEPT for efficient server-side set operations.
  """
  def diff_package_ids(new_id, prev_id) do
    {:ok, %{rows: rows}} =
      Tracker.Repo.query(
        """
        SELECT package_id, 'added' AS type FROM (
          SELECT package_id FROM package_revisions WHERE channel_revision_id = $1
          EXCEPT
          SELECT package_id FROM package_revisions WHERE channel_revision_id = $2
        ) added
        UNION ALL
        SELECT package_id, 'removed' AS type FROM (
          SELECT package_id FROM package_revisions WHERE channel_revision_id = $2
          EXCEPT
          SELECT package_id FROM package_revisions WHERE channel_revision_id = $1
        ) removed
        """,
        [new_id, prev_id]
      )

    Enum.split_with(rows, fn [_, type] -> type == "added" end)
    |> then(fn {added, removed} ->
      {Enum.map(added, &hd/1), Enum.map(removed, &hd/1)}
    end)
  end

  def bulk_insert_all(records) do
    now = DateTime.utc_now(:second)

    records
    |> Stream.map(fn record ->
      record
      |> Map.put(:inserted_at, now)
      |> Map.put(:updated_at, now)
    end)
    |> Stream.chunk_every(@max_rows)
    |> Enum.each(fn chunk ->
      Tracker.Repo.insert_all(
        "package_revisions",
        chunk,
        on_conflict: {:replace, [:version, :updated_at]},
        conflict_target: [:channel_revision_id, :package_id]
      )
    end)
  end
end

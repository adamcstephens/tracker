defmodule Tracker.Nixpkgs.PackageRevision do
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "package_revisions"
    repo Tracker.Repo
  end

  code_interface do
    define :read
    define :list_by_package, args: [:package_id, {:optional, :channel_id}, {:optional, :version}]
    define :load
    define :for_revisions_packages, args: [:channel_revision_ids, :package_ids]
  end

  actions do
    defaults [:read, create: [:version]]

    read :list_by_package do
      argument :package_id, :integer do
        allow_nil? false
      end

      argument :channel_id, :integer
      argument :version, :string

      pagination do
        offset? true
        countable true
        default_limit 15
      end

      prepare build(load: [:channel_revision])

      filter expr(
               package_id == ^arg(:package_id) and
                 if not is_nil(^arg(:channel_id)) do
                   channel_revision.channel_id == ^arg(:channel_id)
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

    read :for_revisions_packages do
      description "Package revisions for a set of packages across a set of channel revisions."

      argument :channel_revision_ids, {:array, :integer}, allow_nil?: false
      argument :package_ids, {:array, :integer}, allow_nil?: false

      filter expr(
               channel_revision_id in ^arg(:channel_revision_ids) and
                 package_id in ^arg(:package_ids)
             )
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
    calculate :channel_name, :string, expr(channel_revision.channel.name)
    calculate :revision_hash, :string, expr(channel_revision.revision)
    calculate :released_at, :utc_datetime, expr(channel_revision.released_at)
  end

  identities do
    identity :unique_package_revision, [:channel_revision_id, :package_id]
  end

  @valid_sort_columns %{
    released_at: "released_at",
    version: "version",
    channel_name: "channel_name",
    revision_hash: "revision"
  }

  @valid_sort_dirs %{asc: "ASC", desc: "DESC"}

  @doc """
  Returns version changes for a package using a SQL window function.

  Only returns revisions where the version differs from the previous revision
  in the same channel (ordered by released_at).

  Returns `{results, total_count}`.

  ## Options

    * `:channel` - filter to a specific channel (pushed inside the window)
    * `:version` - filter by version substring (applied after window comparison)
    * `:sort_by` - sort field, one of #{inspect(Map.keys(@valid_sort_columns))} (default: `:released_at`)
    * `:sort_dir` - sort direction, `:asc` or `:desc` (default: `:desc`)
    * `:limit` - max results (default: 15)
    * `:offset` - offset for pagination (default: 0)
  """
  def version_changes_by_package(package_id, opts \\ []) do
    channel_id = opts[:channel_id]
    version = opts[:version]
    sort_col = Map.get(@valid_sort_columns, opts[:sort_by] || :released_at, "released_at")
    sort_dir = Map.get(@valid_sort_dirs, opts[:sort_dir] || :desc, "DESC")
    limit = opts[:limit] || 15
    offset = opts[:offset] || 0

    sql = """
    WITH ranked AS (
      SELECT pr.id, pr.version, pr.package_id, pr.channel_revision_id,
             c.name AS channel_name, cr.revision, cr.released_at,
             LAG(pr.version) OVER (PARTITION BY cr.channel_id ORDER BY cr.released_at ASC) AS prev_version
      FROM package_revisions pr
      JOIN channel_revisions cr ON cr.id = pr.channel_revision_id
      JOIN channels c ON c.id = cr.channel_id
      WHERE pr.package_id = $1
        AND ($2::bigint IS NULL OR cr.channel_id = $2)
    ),
    version_changes AS (
      SELECT id, version, package_id, channel_revision_id, channel_name, revision, released_at
      FROM ranked
      WHERE version != prev_version OR prev_version IS NULL
    )
    SELECT *, COUNT(*) OVER() AS total_count
    FROM version_changes
    WHERE ($3::text IS NULL OR version LIKE '%' || $3 || '%')
    ORDER BY #{sort_col} #{sort_dir}
    LIMIT $4 OFFSET $5
    """

    version_param = if version != nil and version != "", do: version, else: nil

    case Tracker.Repo.query(sql, [package_id, channel_id, version_param, limit, offset]) do
      {:ok, %{rows: []}} ->
        {[], 0}

      {:ok, %{rows: rows}} ->
        total_count = rows |> hd() |> List.last()

        results =
          Enum.map(rows, fn [
                              id,
                              version,
                              package_id,
                              channel_revision_id,
                              channel_name,
                              revision,
                              released_at,
                              _total_count
                            ] ->
            %__MODULE__.VersionChange{
              id: id,
              version: version,
              package_id: package_id,
              channel_revision_id: channel_revision_id,
              channel_name: channel_name,
              revision: revision,
              released_at: DateTime.from_naive!(released_at, "Etc/UTC")
            }
          end)

        {results, total_count}
    end
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

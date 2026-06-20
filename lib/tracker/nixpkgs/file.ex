defmodule Tracker.Nixpkgs.File do
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "files"
    repo Tracker.Repo
  end

  code_interface do
    define :read
    define :get_by_path, args: [:path]
    define :files_for_prefix, args: [:prefix, :channel_revision_id]
  end

  actions do
    defaults [:read]

    read :get_by_path do
      get? true

      argument :path, :string do
        allow_nil? false
      end

      filter expr(path == ^arg(:path))
    end

    read :files_for_prefix do
      argument :prefix, :string, allow_nil?: false
      argument :channel_revision_id, :integer, allow_nil?: false

      prepare build(sort: :path)

      filter expr(
               exists(
                 option_revision_files,
                 option_revision.channel_revision_id == ^arg(:channel_revision_id) and
                   (option_revision.option.name == ^arg(:prefix) or
                      fragment("? LIKE ? || '.%'", option_revision.option.name, ^arg(:prefix)))
               )
             )
    end
  end

  attributes do
    integer_primary_key :id

    attribute :path, :string do
      allow_nil? false
      public? true
    end

    timestamps()
  end

  relationships do
    has_many :option_file_spans, Tracker.Nixpkgs.OptionFileSpan
    has_many :change_files, Tracker.Nixpkgs.ChangeFile
  end

  identities do
    identity :unique_path, [:path]
  end

  @doc """
  Normalize a file path so option-revision and change ingestion converge on
  the same `files.path` row.

  Trims leading `./` and rewrites the historical `nixos/modules/nixos/modules/`
  duplication that appears in some declarations metadata.
  """
  def normalize_path("./" <> rest), do: normalize_path(rest)

  def normalize_path("nixos/modules/nixos/modules/" <> rest),
    do: "nixos/modules/" <> rest

  def normalize_path(path) when is_binary(path), do: path

  # 3 columns: path, inserted_at, updated_at
  @insert_cols 3
  @max_rows div(65_535, @insert_cols)

  @doc """
  Bulk upsert files using raw Ecto insert_all for performance.

  Returns a map of path => id covering every input record.
  """
  def bulk_upsert_all(paths) do
    now = DateTime.utc_now(:second)

    paths
    |> Stream.map(fn path ->
      %{path: path, inserted_at: now, updated_at: now}
    end)
    |> Stream.chunk_every(@max_rows)
    |> Enum.reduce(%{}, fn chunk, acc ->
      {_count, rows} =
        Tracker.Repo.insert_all(
          "files",
          chunk,
          on_conflict: {:replace, [:updated_at]},
          conflict_target: :path,
          returning: [:id, :path]
        )

      Map.merge(acc, Map.new(rows, fn %{id: id, path: path} -> {path, id} end))
    end)
  end
end

defmodule Tracker.Nixpkgs.OptionRevisionFile do
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "option_revision_files"
    repo Tracker.Repo
  end

  code_interface do
    define :read
  end

  actions do
    defaults [:read]
  end

  attributes do
    integer_primary_key :id

    timestamps()
  end

  relationships do
    belongs_to :option_revision, Tracker.Nixpkgs.OptionRevision,
      attribute_type: :integer,
      allow_nil?: false

    belongs_to :file, Tracker.Nixpkgs.File, attribute_type: :integer, allow_nil?: false
  end

  identities do
    identity :unique_revision_file, [:option_revision_id, :file_id]
  end

  # 5 columns: id, option_revision_id, file_id, inserted_at, updated_at
  @insert_cols 4
  @max_rows div(65_535, @insert_cols)

  @doc """
  Bulk insert option_revision_files records from `%{option_revision_id, file_id}` maps.

  Idempotent on (option_revision_id, file_id).
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
    |> Enum.each(fn chunk ->
      Tracker.Repo.insert_all(
        "option_revision_files",
        chunk,
        on_conflict: :nothing,
        conflict_target: [:option_revision_id, :file_id]
      )
    end)
  end
end

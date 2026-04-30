defmodule Tracker.Nixpkgs.ChangeFile do
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "change_files"
    repo Tracker.Repo
  end

  code_interface do
    define :read
  end

  actions do
    defaults [:read, :destroy]
  end

  attributes do
    integer_primary_key :id

    timestamps()
  end

  relationships do
    belongs_to :change, Tracker.Nixpkgs.Change, attribute_type: :integer, allow_nil?: false
    belongs_to :file, Tracker.Nixpkgs.File, attribute_type: :integer, allow_nil?: false
  end

  identities do
    identity :unique_change_file, [:change_id, :file_id]
  end

  # 5 columns: id, change_id, file_id, inserted_at, updated_at — id is generated
  @insert_cols 4
  @max_rows div(65_535, @insert_cols)

  @doc """
  Bulk insert change_files records from `%{change_id, file_id}` maps.

  Idempotent on (change_id, file_id).
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
        "change_files",
        chunk,
        on_conflict: :nothing,
        conflict_target: [:change_id, :file_id]
      )
    end)
  end

  @doc """
  Bulk-destroys every ChangeFile row belonging to the given change_id.
  Returns `:ok`.
  """
  def clear_for_change!(change_id) do
    require Ash.Query

    __MODULE__
    |> Ash.Query.filter(change_id == ^change_id)
    |> Ash.bulk_destroy!(:destroy, %{}, strategy: :atomic, return_errors?: true)

    :ok
  end
end

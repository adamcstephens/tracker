defmodule Tracker.Nixpkgs.PackageVariantGroup do
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "package_variant_groups"
    repo Tracker.Repo
  end

  code_interface do
    define :read
    define :bulk_upsert, args: [:position]
    define :id_map, action: :id_map
  end

  actions do
    defaults [:read]

    read :id_map do
      prepare build(select: [:position])
    end

    create :bulk_upsert do
      accept [:position]
      upsert? true
      upsert_identity :unique_position
      upsert_fields [:updated_at]
    end
  end

  attributes do
    integer_primary_key :id

    attribute :position, :string do
      allow_nil? false
      public? true
    end

    timestamps()
  end

  relationships do
    has_many :packages, Tracker.Nixpkgs.Package
  end

  identities do
    identity :unique_position, [:position]
  end

  # 3 columns: position, inserted_at, updated_at
  @insert_cols 3
  @max_rows div(65_535, @insert_cols)

  @doc """
  Bulk upsert package variant groups using raw Ecto insert_all for performance.

  Handles chunking internally based on PostgreSQL's parameter limit.
  Expects an enumerable of maps with keys: :position.
  Returns a map of %{position => id}.
  """
  def bulk_upsert_all(records) do
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
          "package_variant_groups",
          chunk,
          on_conflict: {:replace, [:updated_at]},
          conflict_target: [:position],
          returning: [:id, :position]
        )

      Map.merge(acc, Map.new(rows, fn %{id: id, position: pos} -> {pos, id} end))
    end)
  end
end

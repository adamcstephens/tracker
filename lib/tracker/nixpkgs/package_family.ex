defmodule Tracker.Nixpkgs.PackageFamily do
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "package_families"
    repo Tracker.Repo
  end

  code_interface do
    define :read
    define :bulk_upsert, args: [:name]
    define :id_map, action: :id_map
  end

  actions do
    defaults [:read]

    read :id_map do
      prepare build(select: [:name, :ecosystem])
    end

    create :bulk_upsert do
      accept [:name, :ecosystem]
      upsert? true
      upsert_identity :unique_name_ecosystem
      upsert_fields [:updated_at]
    end
  end

  attributes do
    integer_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :ecosystem, :string do
      allow_nil? false
      default ""
      public? true
    end

    timestamps()
  end

  relationships do
    has_many :packages, Tracker.Nixpkgs.Package
  end

  identities do
    identity :unique_name_ecosystem, [:name, :ecosystem]
  end

  # 4 columns: name, ecosystem, inserted_at, updated_at
  @insert_cols 4
  @max_rows div(65_535, @insert_cols)

  @doc """
  Bulk upsert package families using raw Ecto insert_all for performance.

  Handles chunking internally based on PostgreSQL's parameter limit.
  Expects an enumerable of maps with keys: :name, :ecosystem.
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
          "package_families",
          chunk,
          on_conflict: {:replace, [:updated_at]},
          conflict_target: [:name, :ecosystem],
          returning: [:id, :name, :ecosystem]
        )

      Map.merge(
        acc,
        Map.new(rows, fn %{id: id, name: name, ecosystem: eco} -> {{name, eco}, id} end)
      )
    end)
  end
end

defmodule Tracker.Nixpkgs.Option do
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "options"
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
      prepare build(select: [:name])
    end

    create :bulk_upsert do
      accept [:name, :module_id]
      upsert? true
      upsert_identity :unique_name
      upsert_fields [:module_id, :updated_at]
    end
  end

  attributes do
    integer_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :module, Tracker.Nixpkgs.Module do
      attribute_type :integer
      allow_nil? true
    end

    has_many :option_revisions, Tracker.Nixpkgs.OptionRevision
  end

  identities do
    identity :unique_name, [:name]
  end

  # 3 columns: name, module_id, inserted_at, updated_at
  @insert_cols 4
  @max_rows div(65_535, @insert_cols)

  @doc """
  Bulk upsert options using raw Ecto insert_all for performance.

  Returns a map of name => id.
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
          "options",
          chunk,
          on_conflict: {:replace, [:module_id, :updated_at]},
          conflict_target: :name,
          returning: [:id, :name]
        )

      Map.merge(acc, Map.new(rows, fn %{id: id, name: name} -> {name, id} end))
    end)
  end
end

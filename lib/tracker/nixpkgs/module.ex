defmodule Tracker.Nixpkgs.Module do
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "modules"
    repo Tracker.Repo
  end

  code_interface do
    define :read
    define :bulk_upsert, args: [:declaration]
    define :id_map, action: :id_map
  end

  actions do
    defaults [:read]

    read :id_map do
      prepare build(select: [:declaration])
    end

    create :bulk_upsert do
      accept [:declaration, :display_name]
      upsert? true
      upsert_identity :unique_declaration
      upsert_fields [:display_name, :updated_at]
    end
  end

  attributes do
    integer_primary_key :id

    attribute :declaration, :string do
      allow_nil? false
      public? true
    end

    attribute :display_name, :string do
      allow_nil? false
      public? true
    end

    timestamps()
  end

  relationships do
    has_many :options, Tracker.Nixpkgs.Option
  end

  identities do
    identity :unique_declaration, [:declaration]
  end

  # 4 columns: declaration, display_name, inserted_at, updated_at
  @insert_cols 4
  @max_rows div(65_535, @insert_cols)

  @doc """
  Bulk upsert modules using raw Ecto insert_all for performance.

  Returns a map of declaration => id.
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
          "modules",
          chunk,
          on_conflict: {:replace, [:display_name, :updated_at]},
          conflict_target: :declaration,
          returning: [:id, :declaration]
        )

      Map.merge(acc, Map.new(rows, fn %{id: id, declaration: decl} -> {decl, id} end))
    end)
  end
end

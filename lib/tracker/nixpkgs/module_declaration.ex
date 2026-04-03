defmodule Tracker.Nixpkgs.ModuleDeclaration do
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "module_declarations"
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

    attribute :path, :string do
      allow_nil? false
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :module, Tracker.Nixpkgs.Module, attribute_type: :integer, allow_nil?: false
  end

  identities do
    identity :unique_path, [:path]
  end

  # 4 columns: path, module_id, inserted_at, updated_at
  @insert_cols 4
  @max_rows div(65_535, @insert_cols)

  @doc """
  Bulk upsert module declarations using raw Ecto insert_all for performance.

  Accepts records like %{path: "...", module_id: 123}.
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
    |> Enum.each(fn chunk ->
      Tracker.Repo.insert_all(
        "module_declarations",
        chunk,
        on_conflict: {:replace, [:module_id, :updated_at]},
        conflict_target: :path
      )
    end)
  end
end

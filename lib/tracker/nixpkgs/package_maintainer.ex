defmodule Tracker.Nixpkgs.PackageMaintainer do
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "package_maintainers"
    repo Tracker.Repo
  end

  code_interface do
    define :read
    define :load
  end

  actions do
    defaults [:read]

    create :load do
      accept [:package_id, :maintainer_id]
      upsert? true
      upsert_identity :unique_package_maintainer
      upsert_fields [:updated_at]
    end
  end

  attributes do
    integer_primary_key :id
    timestamps()
  end

  relationships do
    belongs_to :package, Tracker.Nixpkgs.Package, attribute_type: :integer, allow_nil?: false

    belongs_to :maintainer, Tracker.Nixpkgs.Maintainer,
      attribute_type: :integer,
      allow_nil?: false
  end

  # 5 columns: id, package_id, maintainer_id, inserted_at, updated_at
  @ash_cols 5
  @max_batch div(65_535, @ash_cols)

  def bulk_create_all(records) do
    records
    |> Stream.chunk_every(@max_batch)
    |> Enum.each(fn chunk ->
      Ash.bulk_create(chunk, __MODULE__, :load,
        batch_size: @max_batch,
        return_errors?: true
      )
    end)
  end

  identities do
    identity :unique_package_maintainer, [:package_id, :maintainer_id]
  end
end

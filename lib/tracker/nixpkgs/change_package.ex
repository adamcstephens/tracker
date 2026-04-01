defmodule Tracker.Nixpkgs.ChangePackage do
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "change_packages"
    repo Tracker.Repo
  end

  code_interface do
    define :read
    define :load
  end

  actions do
    defaults [:read]

    create :load do
      accept [:change_id, :package_id, :type]
      upsert? true
      upsert_identity :unique_change_package
      upsert_fields [:type, :updated_at]
    end
  end

  attributes do
    integer_primary_key :id

    attribute :type, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:added, :changed, :removed]
    end

    timestamps()
  end

  relationships do
    belongs_to :change, Tracker.Nixpkgs.Change, attribute_type: :integer, allow_nil?: false
    belongs_to :package, Tracker.Nixpkgs.Package, attribute_type: :integer, allow_nil?: false
  end

  # 6 columns: id, change_id, package_id, type, inserted_at, updated_at
  @ash_cols 6
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
    identity :unique_change_package, [:change_id, :package_id]
  end
end

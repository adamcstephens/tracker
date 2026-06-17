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
    defaults [:read, :destroy]

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
    Tracker.Nixpkgs.BulkCreate.run!(records, __MODULE__, :load, @max_batch)
  end

  @doc """
  Bulk-destroys every ChangePackage row belonging to the given change_id.
  Returns `:ok`.
  """
  def clear_for_change!(change_id) do
    require Ash.Query

    __MODULE__
    |> Ash.Query.filter(change_id == ^change_id)
    |> Ash.bulk_destroy!(:destroy, %{}, strategy: :atomic, return_errors?: true)

    :ok
  end

  identities do
    identity :unique_change_package, [:change_id, :package_id]
  end
end

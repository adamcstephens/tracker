defmodule Tracker.Nixpkgs.ChangeBranch do
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  alias Tracker.Nixpkgs.Propagation

  postgres do
    table "change_branches"
    repo Tracker.Repo
  end

  code_interface do
    define :read
    define :create
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:change_id, :branch_name, :channel_revision_id, :arrived_at]
      upsert? true
      upsert_identity :unique_change_branch
      upsert_fields [:channel_revision_id, :arrived_at, :updated_at]

      validate {__MODULE__.ValidateBranchName, []}
    end
  end

  attributes do
    integer_primary_key :id

    attribute :branch_name, :string do
      allow_nil? false
      public? true
    end

    attribute :arrived_at, :utc_datetime do
      allow_nil? false
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :change, Tracker.Nixpkgs.Change, attribute_type: :integer, allow_nil?: false

    belongs_to :channel_revision, Tracker.Nixpkgs.ChannelRevision,
      attribute_type: :integer,
      allow_nil?: true
  end

  identities do
    identity :unique_change_branch, [:change_id, :branch_name]
  end

  defmodule ValidateBranchName do
    @moduledoc false
    use Ash.Resource.Validation

    @impl true
    def validate(changeset, _opts, _context) do
      case Ash.Changeset.get_attribute(changeset, :branch_name) do
        nil ->
          :ok

        name when is_binary(name) ->
          if Propagation.valid_branch?(name) do
            :ok
          else
            {:error, field: :branch_name, message: "is not a known propagation branch"}
          end
      end
    end
  end
end

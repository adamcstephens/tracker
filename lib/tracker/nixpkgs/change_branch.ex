defmodule Tracker.Nixpkgs.ChangeBranch do
  use Ash.Resource,
    otp_app: :tracker,
    domain: Tracker.Nixpkgs,
    data_layer: AshPostgres.DataLayer,
    notifiers: [Ash.Notifier.PubSub]

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
      accept [:change_id, :branch_name, :channel_revision_id]
      upsert? true
      upsert_identity :unique_change_branch
      upsert_fields [:channel_revision_id]

      validate {__MODULE__.ValidateBranchName, []}
    end
  end

  pub_sub do
    module Phoenix.PubSub
    name Tracker.PubSub
    prefix "change_branches"

    publish :create, "updated"
  end

  attributes do
    integer_primary_key :id

    attribute :branch_name, :string do
      allow_nil? false
      public? true
    end
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

  @doc """
  Idempotently records `base_ref` as a `ChangeBranch` for `change_id` when
  `base_ref` is part of the propagation graph; no-op otherwise.

  Called from the write paths that transition a Change to `:merged` so the
  merge target is recorded without waiting for the next periodic ancestor
  check.
  """
  @spec seed_for_base_ref(integer(), String.t() | nil) :: :ok
  def seed_for_base_ref(change_id, base_ref) when is_integer(change_id) and is_binary(base_ref) do
    if Propagation.valid_branch?(base_ref) do
      create!(%{change_id: change_id, branch_name: base_ref})
    end

    :ok
  end

  def seed_for_base_ref(_change_id, _base_ref), do: :ok

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

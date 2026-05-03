defmodule Tracker.Nixpkgs.Branch do
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  alias Tracker.Nixpkgs.{Channel, Propagation}

  postgres do
    table "branches"
    repo Tracker.Repo
  end

  code_interface do
    define :read
    define :create
    define :by_name, args: [:name]
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:name, :kind, :channel_id]
      upsert? true
      upsert_identity :unique_name
      upsert_fields [:kind, :channel_id, :updated_at]
    end

    read :by_name do
      get? true
      argument :name, :string, allow_nil?: false
      filter expr(name == ^arg(:name))
    end
  end

  attributes do
    integer_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:branch, :channel]
    end

    timestamps()
  end

  relationships do
    belongs_to :channel, Channel, attribute_type: :integer, allow_nil?: true
    has_many :change_branches, Tracker.Nixpkgs.ChangeBranch
  end

  identities do
    identity :unique_name, [:name]
  end

  @doc """
  Seeds the propagation DAG.

  Creates Branch records for every static branch and every versioned branch
  derived from active stable channels. Channel-kind branches are linked to
  their corresponding Channel via `channel_id`.

  Idempotent.
  """
  def seed! do
    channels_by_name = Channel.read!() |> Map.new(&{&1.name, &1})

    versions = active_release_versions(channels_by_name)

    names =
      Propagation.static_branches() ++
        Enum.flat_map(versions, &Propagation.branches_for_release/1)

    Enum.each(names, fn name ->
      kind = Propagation.kind(name)
      channel = if kind == :channel, do: Map.get(channels_by_name, name), else: nil

      create!(%{
        name: name,
        kind: kind,
        channel_id: channel && channel.id
      })
    end)
  end

  defp active_release_versions(channels_by_name) do
    channels_by_name
    |> Map.keys()
    |> Enum.flat_map(fn name ->
      case Regex.run(~r/^nixos-(\d+\.\d+)$/, name) do
        [_, version] -> [version]
        _ -> []
      end
    end)
    |> Enum.uniq()
  end
end

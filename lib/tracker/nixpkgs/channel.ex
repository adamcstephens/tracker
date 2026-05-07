defmodule Tracker.Nixpkgs.Channel do
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "channels"
    repo Tracker.Repo
  end

  code_interface do
    define :create
    define :read
    define :by_name, args: [:name]
    define :active
    define :nixos_channels
    define :default_stable
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:name, :display_name, :status, :is_stable, :options_source]
      upsert? true
      upsert_identity :unique_name
      upsert_fields [:display_name, :status, :is_stable, :options_source, :updated_at]
    end

    read :by_name do
      get? true

      argument :name, :string, allow_nil?: false

      filter expr(name == ^arg(:name))
    end

    read :active do
      filter expr(status == :active)
      prepare build(sort: [:name])
    end

    read :nixos_channels do
      filter expr(fragment("? LIKE 'nixos-%'", name))
      prepare build(sort: [:name])
    end

    read :default_stable do
      get? true

      filter expr(
               is_stable == true and status == :active and
                 fragment("? ~ '^nixos-\\d+\\.\\d+$'", name)
             )

      prepare build(sort: [{:name, :desc}], limit: 1)
    end
  end

  attributes do
    integer_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :display_name, :string do
      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:active, :retired, :pre_release]
    end

    attribute :is_stable, :boolean do
      allow_nil? false
      public? true
      default false
    end

    attribute :options_source, :string do
      public? true
    end

    timestamps()
  end

  relationships do
    has_many :channel_revisions, Tracker.Nixpkgs.ChannelRevision
  end

  identities do
    identity :unique_name, [:name]
  end

  @doc """
  Seeds channels from the `:tracker, :channels` application config.

  Uses upsert, so safe to call multiple times.
  """
  def seed! do
    Application.fetch_env!(:tracker, :channels)
    |> Enum.each(fn name ->
      create!(%{
        name: name,
        display_name: name,
        status: :active,
        is_stable: stable?(name)
      })
    end)
  end

  defp stable?(name) do
    Regex.match?(~r/^nixos-\d+\.\d+/, name)
  end
end

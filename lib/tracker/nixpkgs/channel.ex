defmodule Tracker.Nixpkgs.Channel do
  use Ash.Resource,
    otp_app: :tracker,
    domain: Tracker.Nixpkgs,
    data_layer: AshPostgres.DataLayer,
    notifiers: [Ash.Notifier.PubSub],
    extensions: [AshAdmin.Resource]

  admin do
    update_actions [:update_status]
  end

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
    define :update_hydra_status
    define :update_status
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
      filter expr(status != :retired)
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

    update :update_hydra_status do
      require_atomic? true

      accept [:hydra_build_failed?, :hydra_project, :hydra_jobset, :hydra_exported_job]

      change set_attribute(:hydra_checked_at, &DateTime.utc_now/0)
    end

    update :update_status do
      accept [:status]
    end
  end

  pub_sub do
    module Phoenix.PubSub
    name Tracker.PubSub
    prefix "channels"

    publish :update_hydra_status, "hydra_status_updated"
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
      constraints one_of: [:active, :retired, :pre_release, :deprecated]
    end

    attribute :is_stable, :boolean do
      allow_nil? false
      public? true
      default false
    end

    attribute :options_source, :string do
      public? true
    end

    attribute :hydra_build_failed?, :boolean do
      public? true
    end

    attribute :hydra_project, :string do
      public? true
    end

    attribute :hydra_jobset, :string do
      public? true
    end

    attribute :hydra_exported_job, :string do
      public? true
    end

    attribute :hydra_checked_at, :utc_datetime_usec do
      public? true
    end

    timestamps()
  end

  relationships do
    has_many :channel_revisions, Tracker.Nixpkgs.ChannelRevision
  end

  calculations do
    calculate :build_problem?,
              :boolean,
              expr(
                not is_nil(hydra_build_failed?) and hydra_build_failed? == true and
                  status != :retired
              )
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

defmodule Tracker.Nixpkgs.BackportLink do
  use Ash.Resource,
    otp_app: :tracker,
    domain: Tracker.Nixpkgs,
    data_layer: AshPostgres.DataLayer,
    notifiers: [Ash.Notifier.PubSub]

  postgres do
    table "backport_links"
    repo Tracker.Repo

    references do
      reference :original, ignore?: true
      reference :backport, on_delete: :delete
    end

    custom_indexes do
      index [:backport_id]
    end
  end

  code_interface do
    define :create
    define :destroy
    define :for_change, args: [:number]
    define :for_backport, args: [:backport_id]
    define :resolve_source
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:source_number, :backport_id, :confidence, :evidence, :source_status]
      upsert? true
      upsert_identity :unique_source_backport
      upsert_fields [:confidence, :evidence, :source_status]
    end

    update :resolve_source do
      accept [:source_status]

      change fn changeset, _context ->
        case Ash.Changeset.get_attribute(changeset, :source_status) do
          :issue -> Ash.Changeset.force_change_attribute(changeset, :confidence, :candidate)
          _status -> changeset
        end
      end

      require_atomic? false
    end

    read :for_change do
      argument :number, :integer, allow_nil?: false
      filter expr(source_number == ^arg(:number) or backport.number == ^arg(:number))
      prepare build(load: [:original, :backport], sort: [source_number: :asc, backport_id: :asc])
    end

    read :for_backport do
      argument :backport_id, :integer, allow_nil?: false
      filter expr(backport_id == ^arg(:backport_id))
    end
  end

  pub_sub do
    module Phoenix.PubSub
    name Tracker.PubSub
    prefix "backport_links"
    publish :create, "updated"
    publish :destroy, "updated"
    publish :resolve_source, "updated"
  end

  attributes do
    integer_primary_key :id
    attribute :source_number, :integer, allow_nil?: false, public?: true

    attribute :confidence, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:confirmed, :candidate]]

    attribute :evidence, {:array, :string}, allow_nil?: false, public?: true, default: []

    attribute :source_status, :atom,
      allow_nil?: false,
      public?: true,
      default: :pending,
      constraints: [one_of: [:pending, :imported, :issue, :not_found]]

    timestamps()
  end

  relationships do
    belongs_to :backport, Tracker.Nixpkgs.Change, attribute_type: :integer, allow_nil?: false

    belongs_to :original, Tracker.Nixpkgs.Change do
      source_attribute :source_number
      destination_attribute :number
      define_attribute? false
    end
  end

  identities do
    identity :unique_source_backport, [:source_number, :backport_id]
  end
end

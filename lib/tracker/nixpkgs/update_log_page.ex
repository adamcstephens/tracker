defmodule Tracker.Nixpkgs.UpdateLogPage do
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "update_log_pages"
    repo Tracker.Repo

    custom_indexes do
      index [:namespace, :package_name]
    end
  end

  code_interface do
    define :read
    define :by_key, args: [:namespace, :package_name]
    define :upsert, args: [:attribute, :url]
    define :destroy
  end

  actions do
    defaults [:read, :destroy]

    read :by_key do
      argument :namespace, :string
      argument :package_name, :string, allow_nil?: false
      filter expr(namespace == ^arg(:namespace) and package_name == ^arg(:package_name))
    end

    create :upsert do
      accept [:attribute, :url]
      upsert? true
      upsert_identity :unique_attribute
      upsert_fields [:url, :namespace, :package_name]

      change fn changeset, _context ->
        attribute = Ash.Changeset.get_attribute(changeset, :attribute)
        {namespace, package_name} = Tracker.Nixpkgs.UpdateLogKey.for_attribute(attribute)

        changeset
        |> Ash.Changeset.force_change_attribute(:namespace, namespace)
        |> Ash.Changeset.force_change_attribute(:package_name, package_name)
      end
    end
  end

  attributes do
    integer_primary_key :id

    attribute :attribute, :string do
      allow_nil? false
      public? true
    end

    attribute :url, :string do
      allow_nil? false
      public? true
    end

    attribute :namespace, :string do
      public? true
    end

    attribute :package_name, :string do
      public? true
    end
  end

  identities do
    identity :unique_attribute, [:attribute]
  end
end

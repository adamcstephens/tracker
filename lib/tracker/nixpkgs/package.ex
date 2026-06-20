defmodule Tracker.Nixpkgs.Package do
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "packages"
    repo Tracker.Repo

    custom_indexes do
      # The packages index default view sorts by inserted_at; without this the
      # planner seq-scans and sorts the whole table for every page load.
      index [:inserted_at]
    end
  end

  code_interface do
    define :read
    define :list, args: [{:optional, :search}, {:optional, :channel_id}]
    define :get_by_attribute, action: :read, get_by: [:attribute]
    define :create
    define :bulk_upsert, args: [:attribute]
    define :by_maintainer, args: [:maintainer_id, {:optional, :search}, {:optional, :channel_id}]
    define :by_team, args: [:team_id, {:optional, :search}, {:optional, :channel_id}]
    define :family_siblings, args: [:package_family_id, :exclude_id]
    define :variant_siblings, args: [:package_variant_group_id, :exclude_id]
    define :id_map, action: :id_map
    define :ids_by_attributes, args: [:attributes]
    define :by_change, args: [:change_id, {:optional, :search}]
  end

  actions do
    defaults [:read]

    read :list do
      argument :search, :ci_string
      argument :channel_id, :integer

      pagination do
        offset? true
        countable true
        default_limit 15
      end

      prepare Tracker.Nixpkgs.Preparations.SortByRelevance

      filter expr(
               if not is_nil(^arg(:search)) and ^arg(:search) != "" do
                 fragment("strict_word_similarity(?, ?) > 0.4", ^arg(:search), attribute) or
                   contains(attribute, ^arg(:search))
               else
                 true
               end and
                 if not is_nil(^arg(:channel_id)) do
                   exists(
                     spans,
                     channel_id == ^arg(:channel_id) and fragment("upper_inf(?)", valid)
                   )
                 else
                   true
                 end
             )
    end

    read :by_maintainer do
      argument :maintainer_id, :integer do
        allow_nil? false
      end

      argument :search, :ci_string
      argument :channel_id, :integer

      pagination do
        offset? true
        countable true
        default_limit 15
      end

      prepare build(sort: :attribute)

      filter expr(
               exists(package_maintainers, maintainer_id == ^arg(:maintainer_id)) and
                 if not is_nil(^arg(:search)) and ^arg(:search) != "" do
                   fragment("strict_word_similarity(?, ?) > 0.4", ^arg(:search), attribute) or
                     contains(attribute, ^arg(:search))
                 else
                   true
                 end and
                 if not is_nil(^arg(:channel_id)) do
                   exists(
                     spans,
                     channel_id == ^arg(:channel_id) and fragment("upper_inf(?)", valid)
                   )
                 else
                   true
                 end
             )
    end

    read :by_team do
      argument :team_id, :integer do
        allow_nil? false
      end

      argument :search, :ci_string
      argument :channel_id, :integer

      pagination do
        offset? true
        countable true
        default_limit 15
      end

      prepare build(sort: :attribute)

      filter expr(
               exists(package_teams, team_id == ^arg(:team_id)) and
                 if not is_nil(^arg(:search)) and ^arg(:search) != "" do
                   fragment("strict_word_similarity(?, ?) > 0.4", ^arg(:search), attribute) or
                     contains(attribute, ^arg(:search))
                 else
                   true
                 end and
                 if not is_nil(^arg(:channel_id)) do
                   exists(
                     spans,
                     channel_id == ^arg(:channel_id) and fragment("upper_inf(?)", valid)
                   )
                 else
                   true
                 end
             )
    end

    read :family_siblings do
      argument :package_family_id, :integer do
        allow_nil? false
      end

      argument :exclude_id, :integer do
        allow_nil? false
      end

      prepare build(sort: :attribute)
      filter expr(package_family_id == ^arg(:package_family_id) and id != ^arg(:exclude_id))
    end

    read :variant_siblings do
      argument :package_variant_group_id, :integer do
        allow_nil? false
      end

      argument :exclude_id, :integer do
        allow_nil? false
      end

      prepare build(sort: :attribute)

      filter expr(
               package_variant_group_id == ^arg(:package_variant_group_id) and
                 id != ^arg(:exclude_id)
             )
    end

    read :by_change do
      argument :change_id, :integer, allow_nil?: false
      argument :search, :ci_string

      pagination do
        offset? true
        countable true
        default_limit 15
      end

      prepare build(sort: :attribute)

      filter expr(
               exists(change_packages, change_id == ^arg(:change_id)) and
                 if not is_nil(^arg(:search)) and ^arg(:search) != "" do
                   fragment("strict_word_similarity(?, ?) > 0.4", ^arg(:search), attribute) or
                     contains(attribute, ^arg(:search))
                 else
                   true
                 end
             )
    end

    read :id_map do
      prepare build(select: [:attribute])
    end

    read :ids_by_attributes do
      argument :attributes, {:array, :string}, allow_nil?: false

      filter expr(attribute in ^arg(:attributes))
    end

    create :create do
      accept [:attribute]
    end

    create :bulk_upsert do
      accept [:attribute, :package_family_id, :package_variant_group_id]

      upsert? true
      upsert_identity :unique_attribute

      upsert_fields [:package_family_id, :package_variant_group_id, :updated_at]
    end
  end

  attributes do
    integer_primary_key :id

    attribute :attribute, :string do
      allow_nil? false
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :package_family, Tracker.Nixpkgs.PackageFamily do
      attribute_type :integer
      allow_nil? true
    end

    belongs_to :package_variant_group, Tracker.Nixpkgs.PackageVariantGroup do
      attribute_type :integer
      allow_nil? true
    end

    has_many :spans, Tracker.Nixpkgs.PackageSpan

    has_many :package_maintainers, Tracker.Nixpkgs.PackageMaintainer
    has_many :package_teams, Tracker.Nixpkgs.PackageTeam

    many_to_many :maintainers, Tracker.Nixpkgs.Maintainer do
      through Tracker.Nixpkgs.PackageMaintainer
      source_attribute_on_join_resource :package_id
      destination_attribute_on_join_resource :maintainer_id
    end

    many_to_many :teams, Tracker.Nixpkgs.Team do
      through Tracker.Nixpkgs.PackageTeam
      source_attribute_on_join_resource :package_id
      destination_attribute_on_join_resource :team_id
    end

    has_many :option_packages, Tracker.Nixpkgs.OptionPackage

    many_to_many :options, Tracker.Nixpkgs.Option do
      through Tracker.Nixpkgs.OptionPackage
      source_attribute_on_join_resource :package_id
      destination_attribute_on_join_resource :option_id
    end

    has_many :change_packages, Tracker.Nixpkgs.ChangePackage

    many_to_many :changes, Tracker.Nixpkgs.Change do
      through Tracker.Nixpkgs.ChangePackage
      source_attribute_on_join_resource :package_id
      destination_attribute_on_join_resource :change_id
    end
  end

  identities do
    identity :unique_attribute, [:attribute]
  end

  # 5 columns: attribute, package_family_id, package_variant_group_id,
  # inserted_at, updated_at
  @insert_cols 5
  @max_rows div(65_535, @insert_cols)

  @doc """
  Bulk upsert packages using raw Ecto insert_all for performance.

  Handles chunking internally based on PostgreSQL's parameter limit. `packages`
  is identity-only; mutable metadata lives on `Tracker.Nixpkgs.PackageSpan`.
  Expects an enumerable of maps with keys: :attribute, and optionally
  :package_family_id, :package_variant_group_id.
  """
  @upsert_fields [
    :package_family_id,
    :package_variant_group_id,
    :updated_at
  ]

  def bulk_upsert_all(records) do
    now = DateTime.utc_now(:second)

    records
    |> Stream.map(fn record ->
      record
      |> Map.put(:inserted_at, now)
      |> Map.put(:updated_at, now)
    end)
    |> Stream.chunk_every(@max_rows)
    |> Enum.reduce(%{}, fn chunk, acc ->
      chunk_keys = chunk |> Enum.flat_map(&Map.keys/1) |> MapSet.new()
      replace_fields = Enum.filter(@upsert_fields, &MapSet.member?(chunk_keys, &1))

      {_count, rows} =
        Tracker.Repo.insert_all(
          "packages",
          chunk,
          on_conflict: {:replace, replace_fields},
          conflict_target: :attribute,
          returning: [:id, :attribute]
        )

      Map.merge(acc, Map.new(rows, fn %{id: id, attribute: attr} -> {attr, id} end))
    end)
  end
end

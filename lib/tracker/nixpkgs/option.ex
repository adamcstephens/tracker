defmodule Tracker.Nixpkgs.Option do
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "options"
    repo Tracker.Repo
  end

  code_interface do
    define :read
    define :list, args: [{:optional, :search}]
    define :bulk_upsert, args: [:name]
    define :id_map, action: :id_map
  end

  actions do
    defaults [:read]

    read :list do
      argument :search, :ci_string

      pagination do
        offset? true
        countable true
        default_limit 15
      end

      prepare build(sort: :name)

      filter expr(
               if not is_nil(^arg(:search)) and ^arg(:search) != "" do
                 fragment("strict_word_similarity(?, ?) > 0.4", ^arg(:search), name) or
                   contains(name, ^arg(:search))
               else
                 true
               end
             )
    end

    read :id_map do
      prepare build(select: [:name])
    end

    create :bulk_upsert do
      accept [:name]
      upsert? true
      upsert_identity :unique_name
      upsert_fields [:updated_at]
    end
  end

  attributes do
    integer_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    timestamps()
  end

  relationships do
    has_many :spans, Tracker.Nixpkgs.OptionSpan

    many_to_many :packages, Tracker.Nixpkgs.Package do
      through Tracker.Nixpkgs.OptionPackage
      source_attribute_on_join_resource :option_id
      destination_attribute_on_join_resource :package_id
    end
  end

  identities do
    identity :unique_name, [:name]
  end

  # 3 columns: name, inserted_at, updated_at
  @insert_cols 3
  @max_rows div(65_535, @insert_cols)

  @doc """
  Returns a sorted `[{prefix, count}, ...]` list of two-segment prefixes
  covering every option affected by the given change *as seen in the given
  channel revision*.

  Maps the change's touched files to the options those files declare — option↔
  file membership, which lands on option file spans in trk-323 (P4). Returns
  `[]` until then.
  """
  def prefix_counts_by_change_and_channel_revision(_change_id, _channel_revision_id) do
    []
  end

  @doc """
  Bulk upsert options using raw Ecto insert_all for performance.

  Returns a map of name => id.
  """
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
      {_count, rows} =
        Tracker.Repo.insert_all(
          "options",
          chunk,
          on_conflict: {:replace, [:updated_at]},
          conflict_target: :name,
          returning: [:id, :name]
        )

      Map.merge(acc, Map.new(rows, fn %{id: id, name: name} -> {name, id} end))
    end)
  end
end

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

  Scoping to a single channel revision is what keeps this query tractable
  on changes that touch foundational files — without it the join fans out
  across every channel revision each option has ever appeared in.

  An option with no dots in its name is returned under its bare name as
  the prefix. Otherwise the prefix is the first two dot-separated segments
  (e.g. `services.nginx.virtualHosts` → `services.nginx`).
  """
  def prefix_counts_by_change_and_channel_revision(change_id, channel_revision_id) do
    file_ids =
      change_id
      |> Tracker.Nixpkgs.ChangeFile.file_ids_for_change!()
      |> Enum.map(& &1.file_id)

    case file_ids do
      [] ->
        []

      _ ->
        Tracker.Nixpkgs.OptionRevision.list_by_channel_revision_and_file_ids!(
          channel_revision_id,
          file_ids
        )
        |> Enum.map(&fold_to_prefix(&1.option.name))
        |> Enum.frequencies()
        |> Enum.sort_by(fn {prefix, _count} -> prefix end)
    end
  end

  defp fold_to_prefix(name) do
    case String.split(name, ".") do
      [single] -> single
      [a, b | _] -> a <> "." <> b
    end
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

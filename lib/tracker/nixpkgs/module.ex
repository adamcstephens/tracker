defmodule Tracker.Nixpkgs.Module do
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "modules"
    repo Tracker.Repo
  end

  code_interface do
    define :read
    define :list, args: [{:optional, :search}]
    define :get_by_name, args: [:name]
    define :children, args: [:parent_name]
    define :bulk_upsert, args: [:display_name]
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

      prepare build(sort: :display_name, load: [:option_count])

      filter expr(
               if not is_nil(^arg(:search)) and ^arg(:search) != "" do
                 contains(display_name, ^arg(:search))
               else
                 true
               end
             )
    end

    read :get_by_name do
      get? true

      argument :name, :string do
        allow_nil? false
      end

      prepare build(load: [:module_declarations])

      filter expr(display_name == ^arg(:name))
    end

    read :children do
      argument :parent_name, :string do
        allow_nil? false
      end

      prepare build(sort: :display_name, load: [:option_count])

      filter expr(
               fragment(
                 "? LIKE ? || '.%' AND ? NOT LIKE ? || '.%.%'",
                 display_name,
                 ^arg(:parent_name),
                 display_name,
                 ^arg(:parent_name)
               )
             )
    end

    read :id_map do
      prepare build(select: [:display_name])
    end

    create :bulk_upsert do
      accept [:display_name]
      upsert? true
      upsert_identity :unique_display_name
      upsert_fields [:updated_at]
    end
  end

  attributes do
    integer_primary_key :id

    attribute :display_name, :string do
      allow_nil? false
      public? true
    end

    timestamps()
  end

  relationships do
    has_many :options, Tracker.Nixpkgs.Option
    has_many :module_declarations, Tracker.Nixpkgs.ModuleDeclaration
  end

  aggregates do
    count :option_count, :options
  end

  identities do
    identity :unique_display_name, [:display_name]
  end

  @doc """
  Derives module records, declaration records, and an option-to-display-name
  mapping from a raw options map (as from options.json).

  Groups options by their declaration path, sub-groups by the first two
  dot-separated segments, and computes display names from the longest
  common prefix.

  Returns `{module_records, declaration_records, option_to_display_name}`.
  """
  def derive_from_options(options_map) do
    options_by_declaration =
      Enum.reduce(options_map, %{}, fn {name, entry}, acc ->
        declaration = resolve_declaration(name, entry["declarations"] || [])
        Map.update(acc, declaration, [name], &[name | &1])
      end)

    declaration_subgroups =
      Enum.flat_map(options_by_declaration, fn {declaration, option_names} ->
        option_names
        |> Enum.group_by(&option_prefix/1)
        |> Enum.map(fn {_prefix, names} ->
          {declaration, names, Tracker.Nixpkgs.ChannelFetcher.display_name_for_options(names)}
        end)
      end)

    by_display_name = Enum.group_by(declaration_subgroups, fn {_, _, dn} -> dn end)

    module_records =
      Enum.map(by_display_name, fn {display_name, _groups} ->
        %{display_name: display_name}
      end)

    declaration_records =
      Enum.flat_map(by_display_name, fn {display_name, groups} ->
        groups
        |> Enum.map(fn {declaration, _, _} -> declaration end)
        |> Enum.uniq()
        |> Enum.map(&%{path: &1, display_name: display_name})
      end)

    option_to_display_name =
      Enum.flat_map(by_display_name, fn {display_name, groups} ->
        Enum.flat_map(groups, fn {_declaration, option_names, _} ->
          Enum.map(option_names, &{&1, display_name})
        end)
      end)
      |> Map.new()

    {module_records, declaration_records, option_to_display_name}
  end

  defp option_prefix(name) do
    case String.split(name, ".") do
      [one] -> one
      parts -> parts |> Enum.take(2) |> Enum.join(".")
    end
  end

  defp resolve_declaration(_name, [first | _rest]), do: normalize_declaration(first)

  defp resolve_declaration(name, []) do
    case String.split(name, ".") do
      [one] -> one
      parts -> parts |> Enum.take(2) |> Enum.join(".")
    end
  end

  defp normalize_declaration("nixos/modules/nixos/modules/" <> rest),
    do: "nixos/modules/" <> rest

  defp normalize_declaration(declaration), do: declaration

  # 3 columns: display_name, inserted_at, updated_at
  @insert_cols 3
  @max_rows div(65_535, @insert_cols)

  @doc """
  Bulk upsert modules using raw Ecto insert_all for performance.

  Returns a map of display_name => id.
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
          "modules",
          chunk,
          on_conflict: {:replace, [:updated_at]},
          conflict_target: :display_name,
          returning: [:id, :display_name]
        )

      Map.merge(acc, Map.new(rows, fn %{id: id, display_name: name} -> {name, id} end))
    end)
  end
end

defmodule Tracker.Nixpkgs.Types.RevisionSummary do
  @moduledoc false

  use Ash.Type

  alias Tracker.Nixpkgs.{OptionHistory, RevisionComparison, RevisionSummary}

  @change_types %{"added" => :added, "removed" => :removed, "changed" => :changed}
  @metadata_fields %{
    "description" => :description,
    "type" => :type,
    "default" => :default,
    "example" => :example,
    "read_only" => :read_only
  }

  @impl Ash.Type
  def storage_type(_constraints), do: :map

  @impl Ash.Type
  def cast_input(nil, _constraints), do: {:ok, nil}
  def cast_input(%{__struct__: RevisionSummary} = summary, _constraints), do: {:ok, summary}
  def cast_input(_value, _constraints), do: :error

  @impl Ash.Type
  def cast_stored(nil, _constraints), do: {:ok, nil}

  def cast_stored(%{"counts" => counts, "results" => rows}, _constraints) do
    {:ok,
     struct!(RevisionSummary,
       counts:
         struct!(RevisionComparison.Counts,
           added: Map.fetch!(counts, "added"),
           removed: Map.fetch!(counts, "removed"),
           changed: Map.fetch!(counts, "changed")
         ),
       results: Enum.map(rows, &load_row/1)
     )}
  end

  def cast_stored(_value, _constraints), do: :error

  @impl Ash.Type
  def dump_to_native(nil, _constraints), do: {:ok, nil}

  def dump_to_native(%{__struct__: RevisionSummary} = summary, _constraints) do
    {:ok, dump_value(summary)}
  end

  def dump_to_native(_value, _constraints), do: :error

  # The resource must compile before the comparison helper, so construct the
  # known structs at runtime rather than introducing a resource/type cycle.
  defp load_row(%{"attribute" => attribute} = row) do
    struct!(RevisionComparison.PackageRow,
      attribute: attribute,
      type: Map.fetch!(@change_types, Map.fetch!(row, "type")),
      old_version: Map.fetch!(row, "old_version"),
      new_version: Map.fetch!(row, "new_version")
    )
  end

  defp load_row(%{"name" => name} = row) do
    struct!(RevisionComparison.OptionRow,
      name: name,
      type: Map.fetch!(@change_types, Map.fetch!(row, "type")),
      fields: Enum.map(Map.fetch!(row, "fields"), &load_field/1)
    )
  end

  defp load_field(field) do
    struct!(OptionHistory.MetadataDiff,
      option_name: Map.fetch!(field, "option_name"),
      field: Map.fetch!(@metadata_fields, Map.fetch!(field, "field")),
      old: Map.fetch!(field, "old"),
      new: Map.fetch!(field, "new")
    )
  end

  defp dump_value(value) when is_struct(value), do: dump_value(Map.from_struct(value))

  defp dump_value(value) when is_map(value) do
    Map.new(value, fn {key, value} -> {to_string(key), dump_value(value)} end)
  end

  defp dump_value(value) when is_list(value), do: Enum.map(value, &dump_value/1)
  defp dump_value(value) when value in [nil, true, false], do: value
  defp dump_value(value) when is_atom(value), do: Atom.to_string(value)
  defp dump_value(value), do: value
end

defmodule Tracker.Fixtures do
  @moduledoc """
  Test helpers for setting up ingestion data.
  """

  alias Tracker.Ingestion.Helpers

  @doc """
  Loads options data into the database for a channel revision.

  Accepts a raw options map (as from options.json) and a channel revision.
  Upserts modules, declarations, options, and option revisions.
  """
  def load_options(options_map, channel_revision) do
    {module_records, declaration_records, option_to_display_name} =
      Tracker.Nixpkgs.Module.derive_from_options(options_map)

    module_id_map = Tracker.Nixpkgs.Module.bulk_upsert_all(module_records)

    declaration_records
    |> Enum.map(fn %{path: path, display_name: dn} ->
      %{path: path, module_id: Map.fetch!(module_id_map, dn)}
    end)
    |> Tracker.Nixpkgs.ModuleDeclaration.bulk_upsert_all()

    option_records =
      Enum.map(options_map, fn {name, _entry} ->
        display_name = Map.get(option_to_display_name, name)
        module_id = if display_name, do: Map.get(module_id_map, display_name)

        %{name: name}
        |> Helpers.maybe_put(:module_id, module_id)
      end)

    option_id_map = Tracker.Nixpkgs.Option.bulk_upsert_all(option_records)

    options_map
    |> Enum.map(fn {name, entry} ->
      %{
        option_id: Map.fetch!(option_id_map, name),
        channel_revision_id: channel_revision.id,
        description: entry["description"],
        type: entry["type"],
        default: extract_text(entry["default"]),
        example: extract_text(entry["example"]),
        read_only: entry["readOnly"] || false,
        loc: entry["loc"],
        declarations: entry["declarations"],
        related_packages: entry["relatedPackages"]
      }
    end)
    |> Tracker.Nixpkgs.OptionRevision.bulk_insert_all()

    :ok
  end

  defp extract_text(%{"text" => text}), do: text
  defp extract_text(_), do: nil
end

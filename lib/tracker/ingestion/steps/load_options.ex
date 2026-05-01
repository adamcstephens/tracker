defmodule Tracker.Ingestion.Steps.LoadOptions do
  @moduledoc """
  Fetches options.json.br and bulk upserts options, option revisions, files,
  and option-revision-file links.
  """

  @behaviour Tracker.Ingestion.Step

  alias Tracker.Nixpkgs.ChannelFetcher

  @impl true
  def timeout, do: :timer.minutes(15)

  @impl true
  def run(%Tracker.Ingestion.StepContext{pipeline: pipeline, channel_revision: channel_revision}) do
    options_map = ChannelFetcher.fetch_options(pipeline.base_url)

    option_records =
      Enum.map(options_map, fn {name, _entry} -> %{name: name} end)

    option_id_map = Tracker.Nixpkgs.Option.bulk_upsert_all(option_records)

    revision_records =
      Enum.map(options_map, fn {name, entry} ->
        %{
          option_id: Map.fetch!(option_id_map, name),
          channel_revision_id: channel_revision.id,
          description: entry["description"],
          type: entry["type"],
          default: extract_text(entry["default"]),
          example: extract_text(entry["example"]),
          read_only: entry["readOnly"] || false,
          loc: entry["loc"],
          related_packages: entry["relatedPackages"]
        }
      end)

    option_revision_id_map = Tracker.Nixpkgs.OptionRevision.bulk_insert_all(revision_records)

    declaration_paths =
      options_map
      |> Enum.flat_map(fn {_name, entry} -> entry["declarations"] || [] end)
      |> Enum.map(&Tracker.Nixpkgs.File.normalize_path/1)
      |> Enum.uniq()

    file_id_map = Tracker.Nixpkgs.File.bulk_upsert_all(declaration_paths)

    option_revision_file_records =
      options_map
      |> Enum.flat_map(fn {name, entry} ->
        option_id = Map.fetch!(option_id_map, name)
        revision_id = Map.fetch!(option_revision_id_map, option_id)

        (entry["declarations"] || [])
        |> Enum.map(&Tracker.Nixpkgs.File.normalize_path/1)
        |> Enum.uniq()
        |> Enum.map(fn path ->
          %{option_revision_id: revision_id, file_id: Map.fetch!(file_id_map, path)}
        end)
      end)

    Tracker.Nixpkgs.OptionRevisionFile.bulk_insert_all(option_revision_file_records)

    :ok
  end

  defp extract_text(%{"text" => text}), do: text
  defp extract_text(_), do: nil
end

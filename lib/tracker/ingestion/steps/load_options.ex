defmodule Tracker.Ingestion.Steps.LoadOptions do
  @moduledoc """
  Fetches options.json.br, upserts options, and folds this revision's full
  option set into metadata spans via the diff_and_apply engine.

  The same snapshot also drives option↔file (declaration) membership spans:
  because both span sets come from one complete fetch, every membership key's
  option is present in the revision's option set, upholding the "file-membership
  span ⊆ option existence span" invariant without an FK.
  """

  @behaviour Tracker.Ingestion.Step

  alias Tracker.Nixpkgs.{ChannelFetcher, File, Option, OptionFileSpan, OptionSpan, SpanEngine}

  @impl true
  def timeout, do: :timer.minutes(15)

  @impl true
  def run(%Tracker.Ingestion.StepContext{pipeline: pipeline, channel_revision: channel_revision}) do
    options_map = ChannelFetcher.fetch_options(pipeline.base_url)

    option_records = Enum.map(options_map, fn {name, _entry} -> %{name: name} end)
    option_id_map = Option.bulk_upsert_all(option_records)

    # Metadata is temporal: fold this revision's full set into the option spans.
    # The set was just fetched in full, so it is complete — absent options are
    # genuine removals.
    incoming =
      Enum.map(options_map, fn {name, entry} ->
        %{
          option_id: Map.fetch!(option_id_map, name),
          description: entry["description"],
          type: entry["type"],
          default: extract_text(entry["default"]),
          example: extract_text(entry["example"]),
          read_only: entry["readOnly"] || false,
          loc: entry["loc"],
          related_packages: entry["relatedPackages"]
        }
      end)

    SpanEngine.diff_and_apply(
      OptionSpan.spec(),
      channel_revision.channel_id,
      channel_revision.released_at,
      incoming,
      complete?: true
    )

    load_option_files(options_map, option_id_map, channel_revision)

    :ok
  end

  # Folds option↔file (declaration) membership into spans. Membership carries no
  # payload, so a span is open exactly while the file declares the option; a
  # file move closes the old path's key and opens the new one.
  defp load_option_files(options_map, option_id_map, channel_revision) do
    paths =
      options_map
      |> Enum.flat_map(fn {_name, entry} -> entry["declarations"] || [] end)
      |> Enum.map(&File.normalize_path/1)
      |> Enum.uniq()

    file_id_map = File.bulk_upsert_all(paths)

    incoming =
      for {name, entry} <- options_map,
          path <- entry["declarations"] || [],
          uniq: true do
        %{
          option_id: Map.fetch!(option_id_map, name),
          file_id: Map.fetch!(file_id_map, File.normalize_path(path))
        }
      end

    SpanEngine.diff_and_apply(
      OptionFileSpan.spec(),
      channel_revision.channel_id,
      channel_revision.released_at,
      incoming,
      complete?: true
    )
  end

  defp extract_text(%{"text" => text}), do: text
  defp extract_text(_), do: nil
end

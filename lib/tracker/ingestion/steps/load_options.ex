defmodule Tracker.Ingestion.Steps.LoadOptions do
  @moduledoc """
  Fetches options.json.br, upserts options, and folds this revision's full
  option set into metadata spans via the diff_and_apply engine.

  Option↔file (declaration) membership is a separate span vertical (trk-323).
  """

  @behaviour Tracker.Ingestion.Step

  alias Tracker.Nixpkgs.{ChannelFetcher, Option, OptionSpan, SpanEngine}

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

    :ok
  end

  defp extract_text(%{"text" => text}), do: text
  defp extract_text(_), do: nil
end

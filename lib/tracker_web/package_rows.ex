defmodule TrackerWeb.PackageRows do
  @moduledoc """
  Decorates identity-only `Package` rows with current metadata for browse
  tables. Package metadata (description, …) lives on spans; the current value
  is served from the open span in the lens channel, falling back to the
  metadata channel (all-channels lens, package absent from the lens channel,
  or spans written before metadata was ingested on every channel).
  """

  alias Tracker.Ingestion.StepGraph
  alias Tracker.Nixpkgs.{Channel, PackageHistory}

  @doc """
  Maps packages to display rows carrying their current description:
  `%{id:, attribute:, inserted_at:, description:}`.
  """
  def with_current_descriptions([], _lens_channel_id), do: []

  def with_current_descriptions(packages, lens_channel_id) do
    package_ids = Enum.map(packages, & &1.id)
    lens_spans = lens_spans(lens_channel_id, package_ids)
    fallback_spans = metadata_channel_spans(package_ids -- Map.keys(lens_spans))
    spans = Map.merge(fallback_spans, lens_spans)

    Enum.map(packages, fn package ->
      span = Map.get(spans, package.id)

      %{
        id: package.id,
        attribute: package.attribute,
        inserted_at: Map.get(package, :inserted_at),
        description: span && span.description
      }
    end)
  end

  defp lens_spans(nil, _package_ids), do: %{}

  defp lens_spans(channel_id, package_ids) do
    channel_id
    |> PackageHistory.current_metadata(package_ids)
    |> Map.reject(fn {_package_id, span} -> PackageHistory.metadata_missing?(span) end)
  end

  defp metadata_channel_spans(package_ids) do
    case Channel.by_name(StepGraph.metadata_channel()) do
      {:ok, channel} -> PackageHistory.current_metadata(channel.id, package_ids)
      _ -> %{}
    end
  end
end

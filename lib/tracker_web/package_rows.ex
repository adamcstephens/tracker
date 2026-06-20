defmodule TrackerWeb.PackageRows do
  @moduledoc """
  Decorates identity-only `Package` rows with current-channel metadata for
  browse tables. Package metadata (description, …) lives on spans now; the
  current value is served from the open span in the metadata channel via the
  `package_spans_current` partial index.
  """

  alias Tracker.Ingestion.StepGraph
  alias Tracker.Nixpkgs.{Channel, PackageHistory}

  @doc """
  Maps packages to display rows carrying their current description:
  `%{id:, attribute:, inserted_at:, description:}`.
  """
  def with_current_descriptions([]), do: []

  def with_current_descriptions(packages) do
    descriptions =
      case metadata_channel_id() do
        nil ->
          %{}

        channel_id ->
          channel_id
          |> PackageHistory.current_metadata(Enum.map(packages, & &1.id))
          |> Map.new(fn {package_id, span} -> {package_id, span.description} end)
      end

    Enum.map(packages, fn package ->
      %{
        id: package.id,
        attribute: package.attribute,
        inserted_at: Map.get(package, :inserted_at),
        description: Map.get(descriptions, package.id)
      }
    end)
  end

  defp metadata_channel_id do
    case Channel.by_name(StepGraph.metadata_channel()) do
      {:ok, channel} -> channel.id
      _ -> nil
    end
  end
end

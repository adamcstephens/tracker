defmodule Tracker.Ingestion.Steps.LinkOptions do
  @moduledoc """
  Links options to packages via OptionPackageLinker.

  Re-fetches options.json.br and queries option/package IDs from DB.
  Depends on both load_packages and load_options completing first.
  """

  @behaviour Tracker.Ingestion.Step

  import Ecto.Query

  alias Tracker.Nixpkgs.{ChannelFetcher, OptionPackageLinker}

  @impl true
  def timeout, do: :timer.minutes(5)

  @impl true
  def run(%Tracker.Ingestion.StepContext{pipeline: pipeline}) do
    options_map = ChannelFetcher.fetch_options(pipeline.base_url)

    links = OptionPackageLinker.extract_links(options_map)

    attr_paths = links |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    package_id_map =
      case attr_paths do
        [] ->
          %{}

        paths ->
          Tracker.Nixpkgs.Package.ids_by_attributes!(paths)
          |> Map.new(&{&1.attribute, &1.id})
      end

    {option_id_map, option_module_map} = load_option_maps()

    links
    |> Enum.flat_map(fn {option_name, attr_path} ->
      with {:ok, option_id} <- Map.fetch(option_id_map, option_name),
           {:ok, package_id} <- Map.fetch(package_id_map, attr_path) do
        [
          %{
            option_id: option_id,
            package_id: package_id,
            module_id: Map.get(option_module_map, option_name)
          }
        ]
      else
        _ -> []
      end
    end)
    |> Enum.uniq()
    |> Tracker.Nixpkgs.OptionPackage.bulk_create_all()

    :ok
  end

  defp load_option_maps do
    rows =
      from(o in "options", select: {o.name, o.id, o.module_id})
      |> Tracker.Repo.all()

    id_map = Map.new(rows, fn {name, id, _} -> {name, id} end)
    module_map = Map.new(rows, fn {name, _, module_id} -> {name, module_id} end)

    {id_map, module_map}
  end
end

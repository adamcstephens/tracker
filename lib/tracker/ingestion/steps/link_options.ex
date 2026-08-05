defmodule Tracker.Ingestion.Steps.LinkOptions do
  @moduledoc """
  Folds this revision's option↔package links into link spans via the
  diff_and_apply engine.

  Re-fetches options.json.br rather than deriving from the option spans:
  `relatedPackages` is not part of the span payload. Same revision, same
  snapshot. Depends on both load_packages and load_options completing first —
  it resolves package attributes to ids.
  """

  @behaviour Tracker.Ingestion.Step

  import Ecto.Query

  alias Tracker.Nixpkgs.{ChannelFetcher, OptionPackageLinker, OptionPackageSpan, SpanEngine}

  @impl true
  def timeout, do: :timer.minutes(5)

  @impl true
  def run(%Tracker.Ingestion.StepContext{pipeline: pipeline, channel_revision: channel_revision}) do
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

    option_id_map = load_option_id_map()

    incoming =
      links
      |> Enum.flat_map(fn {option_name, attr_path} ->
        with {:ok, option_id} <- Map.fetch(option_id_map, option_name),
             {:ok, package_id} <- Map.fetch(package_id_map, attr_path) do
          [%{option_id: option_id, package_id: package_id}]
        else
          _ -> []
        end
      end)
      |> Enum.uniq()

    # The link set was just extracted from a full options.json, so it is
    # complete — absent links are genuine removals and get closed.
    SpanEngine.diff_and_apply(
      OptionPackageSpan.spec(),
      channel_revision.channel_id,
      channel_revision.released_at,
      incoming,
      complete?: true
    )

    :ok
  end

  defp load_option_id_map do
    from(o in "options", select: {o.name, o.id})
    |> Tracker.Repo.all()
    |> Map.new(fn {name, id} -> {name, id} end)
  end
end

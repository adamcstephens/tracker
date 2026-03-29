defmodule Mix.Tasks.Tracker.BackfillFamilies do
  @shortdoc "Backfills package_family_id, package_set, and set_version for existing packages"
  @moduledoc """
  Parses all existing package attributes through PackageSetMapping,
  creates missing PackageFamily records, and updates packages with
  family associations and parsed set metadata.

  ## Usage

      mix tracker.backfill_families
  """

  use Mix.Task

  require Logger

  @chunk_size 10_000

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    alias Tracker.Nixpkgs.PackageSetMapping

    # Step 1: Read all package attributes
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(Tracker.Repo, "SELECT id, attribute FROM packages")

    Logger.info("Backfilling families for #{length(rows)} packages")

    # Step 2: Parse all attributes
    parsed =
      Enum.map(rows, fn [id, attribute] ->
        {id, attribute, PackageSetMapping.parse(attribute)}
      end)

    # Step 3: Collect and upsert unique families
    families =
      parsed
      |> Enum.filter(fn {_, _, p} -> p.family_name != nil end)
      |> Enum.uniq_by(fn {_, _, p} -> {p.family_name, p.ecosystem} end)
      |> Enum.map(fn {_, _, p} -> %{name: p.family_name, ecosystem: p.ecosystem || ""} end)

    families
    |> Stream.chunk_every(@chunk_size)
    |> Enum.each(fn chunk ->
      Ash.bulk_create(chunk, Tracker.Nixpkgs.PackageFamily, :bulk_upsert,
        batch_size: 5000,
        return_errors?: true
      )
    end)

    Logger.info("Upserted #{length(families)} package families")

    # Step 4: Build family lookup
    %{rows: family_rows} =
      Ecto.Adapters.SQL.query!(Tracker.Repo, "SELECT name, ecosystem, id FROM package_families")

    family_id_map = Map.new(family_rows, fn [name, eco, id] -> {{name, eco}, id} end)

    # Step 5: Update packages via bulk upsert
    parsed
    |> Stream.map(fn {_id, attribute, p} ->
      family_id =
        if p.family_name,
          do: Map.get(family_id_map, {p.family_name, p.ecosystem || ""}),
          else: nil

      %{attribute: attribute}
      |> maybe_put(:package_family_id, family_id)
      |> maybe_put(:package_set, p.package_set)
      |> maybe_put(:set_version, p.set_version)
    end)
    |> Stream.chunk_every(@chunk_size)
    |> Enum.each(fn chunk ->
      Ash.bulk_create(chunk, Tracker.Nixpkgs.Package, :bulk_upsert,
        batch_size: 5000,
        return_errors?: true
      )
    end)

    Logger.info("Backfill complete")
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

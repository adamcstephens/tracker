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
    packages = Tracker.Nixpkgs.Package.read!()

    Logger.info(msg: "backfilling families", packages: length(packages))

    # Step 2: Parse all attributes
    parsed =
      Enum.map(packages, fn pkg ->
        {pkg.id, pkg.attribute, PackageSetMapping.parse(pkg.attribute)}
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

    Logger.info(msg: "upserted package families", count: length(families))

    # Step 4: Build family lookup
    family_id_map =
      Tracker.Nixpkgs.PackageFamily.read!()
      |> Map.new(&{{&1.name, &1.ecosystem}, &1.id})

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

    Logger.info(msg: "backfill complete")
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

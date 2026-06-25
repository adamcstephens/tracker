defmodule Tracker.Nixpkgs.SpanBackfill do
  @moduledoc """
  Historical span backfill driver and reconstruction verifier (epic trk-318 P5).

  `run/2` drives a chronological, resumable backfill via the existing pipeline
  infrastructure; `verify_revision/2` asserts a revision's spans reconstruct its
  source JSON across all three domains.
  """

  alias Tracker.Ingestion.{PackageStream, PipelineStarter}

  alias Tracker.Nixpkgs.{
    Channel,
    ChannelFetcher,
    Option,
    OptionFileSpan,
    OptionSpan,
    ReleaseCache,
    SpanEngine
  }

  @stream_timeout :timer.minutes(10)

  @doc """
  Kicks off (or resumes) a chronological historical backfill for `channel_name`
  over the window `[from, until]` (`until` defaults to now). Bounding the window
  avoids resolving every later release upfront, so the earliest history can be
  ingested in slices. Drives the existing predecessor-linked pipeline backfill,
  one revision at a time; resumable — re-running continues from the last
  completed pipeline.
  """
  @spec run(String.t(), DateTime.t(), DateTime.t() | nil) :: :noop | {:ok, non_neg_integer()}
  def run(channel_name, from, until \\ nil) do
    channel = Channel.by_name!(channel_name)
    :ok = ReleaseCache.refresh_channel(ReleaseCache, channel_name, from: from, until: until)
    PipelineStarter.sync_channel(channel, bootstrap: true, after: from)
  end

  @doc """
  Verifies that `channel_revision`'s spans reconstruct the source JSON at
  `base_url`, for packages, options, and option↔file membership. Returns
  `%{packages:, options:, option_files:}`, each `:ok` or `{:error, detail}`.
  """
  @spec verify_revision(Tracker.Nixpkgs.ChannelRevision.t(), String.t()) :: %{
          packages: :ok | {:error, map()},
          options: :ok | {:error, map()},
          option_files: :ok | {:error, map()}
        }
  def verify_revision(channel_revision, base_url) do
    options = ChannelFetcher.fetch_options(base_url)
    option_ids = Option.id_map!() |> Map.new(&{&1.name, &1.id})

    %{
      packages: verify_packages(channel_revision, base_url),
      options: verify_options(channel_revision, options, option_ids),
      option_files: verify_option_files(channel_revision, options, option_ids)
    }
  end

  defp verify_options(cr, options, option_ids) do
    expected =
      Map.new(options, fn {name, entry} ->
        {[option_ids[name]],
         %{
           description: entry["description"],
           type: entry["type"],
           default: extract_text(entry["default"]),
           example: extract_text(entry["example"]),
           read_only: entry["readOnly"] || false,
           loc: entry["loc"],
           related_packages: entry["relatedPackages"]
         }}
      end)

    SpanEngine.verify(OptionSpan.spec(), cr.channel_id, cr.released_at, expected)
  end

  defp verify_option_files(cr, options, option_ids) do
    norm = &Tracker.Nixpkgs.File.normalize_path/1

    paths =
      options
      |> Enum.flat_map(fn {_n, e} -> e["declarations"] || [] end)
      |> Enum.map(norm)
      |> Enum.uniq()

    file_ids =
      Tracker.Repo.query!("SELECT path, id FROM files WHERE path = ANY($1)", [paths]).rows
      |> Map.new(fn [p, i] -> {p, i} end)

    expected =
      for {name, entry} <- options, path <- entry["declarations"] || [], uniq: true, into: %{} do
        {[option_ids[name], file_ids[norm.(path)]], %{}}
      end

    SpanEngine.verify(OptionFileSpan.spec(), cr.channel_id, cr.released_at, expected)
  end

  # Compares every package's version at the revision against the source, by
  # re-streaming packages.json (the full payload extraction lives in ingestion;
  # version is the primary fingerprint field and exercises the whole path).
  defp verify_packages(cr, base_url) do
    source = stream_versions(base_url)

    reconstructed =
      Tracker.Repo.query!(
        """
        SELECT p.attribute, s.version
        FROM package_spans s JOIN packages p ON p.id = s.package_id
        WHERE s.channel_id = $1 AND s.valid @> $2::timestamptz
        """,
        [cr.channel_id, cr.released_at]
      ).rows
      |> Map.new(fn [attribute, version] -> {attribute, version} end)

    if source == reconstructed do
      :ok
    else
      {:error,
       %{
         source_count: map_size(source),
         reconstructed_count: map_size(reconstructed),
         only_in_source: Map.keys(source) -- Map.keys(reconstructed),
         only_in_spans: Map.keys(reconstructed) -- Map.keys(source),
         version_mismatch:
           for(
             k <- Map.keys(source),
             Map.has_key?(reconstructed, k),
             source[k] != reconstructed[k],
             do: k
           )
       }}
    end
  end

  defp stream_versions(base_url) do
    compressed = ChannelFetcher.fetch_packages_compressed(base_url)
    parent = self()
    task = Task.async(fn -> PackageStream.stream_packages(compressed, parent) end)
    versions = collect_versions(%{})
    :ok = Task.await(task, @stream_timeout)
    versions
  end

  defp collect_versions(acc) do
    receive do
      {:packages, entries} ->
        collect_versions(
          Enum.reduce(entries, acc, fn {attr, f}, m -> Map.put(m, attr, f[:version]) end)
        )

      {:done, _} ->
        acc

      {:error, reason} ->
        raise "PackageStream error: #{inspect(reason)}"
    after
      @stream_timeout -> raise "PackageStream timed out"
    end
  end

  defp extract_text(%{"text" => text}), do: text
  defp extract_text(_), do: nil
end

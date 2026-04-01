defmodule Tracker.Nixpkgs.OptionsWorker do
  use Oban.Worker, queue: :channels, max_attempts: 10

  require Logger

  @doc """
  Backfills options for successful channel revisions that have no option_revisions.

  Looks up base_urls from ReleaseCache and schedules OptionsWorker jobs
  oldest-first for each revision that needs options ingested.
  """
  def backfill_channel(channel, opts \\ []) do
    limit = Keyword.get(opts, :limit)

    # Find successful revisions that have no option_revisions
    revisions_needing_options =
      Tracker.Nixpkgs.ChannelRevision.without_options!(channel)

    jobs_to_schedule =
      Enum.flat_map(revisions_needing_options, fn %{revision: revision} ->
        case Tracker.Nixpkgs.ReleaseCache.find_by_revision(channel, revision) do
          %{base_url: base_url} ->
            [%{revision: revision, base_url: base_url}]

          nil ->
            Logger.warning("No release found for revision #{revision} during options backfill")
            []
        end
      end)

    jobs_to_schedule = if limit, do: Enum.take(jobs_to_schedule, limit), else: jobs_to_schedule

    case jobs_to_schedule do
      [] ->
        {:ok, 0}

      [first | rest] ->
        new(%{
          "channel" => channel,
          "base_url" => first.base_url,
          "revision" => first.revision,
          "remaining" => length(rest)
        })
        |> Oban.insert!()

        {:ok, length(jobs_to_schedule)}
    end
  end

  @doc """
  Schedules the next backfill job by finding the next revision needing options.

  Called after a backfill job completes. No-op for non-backfill jobs.
  """
  def schedule_next(%{"remaining" => remaining, "channel" => channel})
      when remaining > 0 do
    # Find the next successful revision that still has no option_revisions
    case next_revision_needing_options(channel) do
      nil ->
        :ok

      %{revision: revision} ->
        case Tracker.Nixpkgs.ReleaseCache.find_by_revision(channel, revision) do
          %{base_url: base_url} ->
            new(%{
              "channel" => channel,
              "base_url" => base_url,
              "revision" => revision,
              "remaining" => remaining - 1
            })
            |> Oban.insert!()

          nil ->
            Logger.warning("No release found for revision #{revision} during options backfill")
        end
    end
  end

  def schedule_next(_args), do: :ok

  defp next_revision_needing_options(channel) do
    Tracker.Nixpkgs.ChannelRevision.without_options!(channel, query: [limit: 1])
    |> List.first()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"channel" => channel, "base_url" => base_url, "revision" => revision} = args
      }) do
    case Tracker.Nixpkgs.ChannelRevision.find(channel, revision) do
      {:ok, %Tracker.Nixpkgs.ChannelRevision{result: :success} = channel_revision} ->
        fetch_options(base_url)
        |> write_to_database(channel_revision)

        Tracker.Nixpkgs.ChannelRevision.record_options_result!(channel_revision, %{
          options_result: :success
        })

        schedule_next(args)
        :ok

      _ ->
        {:snooze, 60}
    end
  end

  def fetch_options(base_url) do
    Req.get!(Tracker.Nixpkgs.S3Cache.new(), url: base_url <> "/options.json.br", raw: true).body
    |> ExBrotli.decompress!()
    |> :json.decode()
  end

  def write_to_database(options_map, channel_revision) do
    # Step 1: Derive modules from declarations
    {module_records, option_to_declaration} = derive_modules(options_map)

    # Step 2: Bulk upsert modules
    module_id_map = Tracker.Nixpkgs.Module.bulk_upsert_all(module_records)

    # Step 3: Bulk upsert options
    option_records =
      Enum.map(options_map, fn {name, _entry} ->
        declaration = Map.get(option_to_declaration, name)
        module_id = if declaration, do: Map.get(module_id_map, declaration)

        %{name: name}
        |> maybe_put(:module_id, module_id)
      end)

    option_id_map = Tracker.Nixpkgs.Option.bulk_upsert_all(option_records)

    # Step 4: Bulk insert option revisions
    options_map
    |> Enum.map(fn {name, entry} ->
      %{
        option_id: Map.fetch!(option_id_map, name),
        channel_revision_id: channel_revision.id,
        description: entry["description"],
        type: entry["type"],
        default: extract_text(entry["default"]),
        example: extract_text(entry["example"]),
        read_only: entry["readOnly"] || false,
        loc: entry["loc"],
        declarations: entry["declarations"],
        related_packages: entry["relatedPackages"]
      }
    end)
    |> Tracker.Nixpkgs.OptionRevision.bulk_insert_all()

    # Step 5: Link options to packages
    link_options_to_packages(options_map, option_id_map)

    # Step 6: Detect option events if there's a previous revision
    if channel_revision.previous_channel_revision_id do
      detect_option_events(channel_revision)
    end

    :ok
  end

  @doc """
  Computes the longest common dot-separated prefix for a list of option names.

  For a single option name, returns all but the last segment (or the name itself if single-segment).
  """
  def display_name_for_options([single]) do
    case String.split(single, ".") do
      [one] -> one
      parts -> parts |> Enum.drop(-1) |> Enum.join(".")
    end
  end

  def display_name_for_options(option_names) do
    split_names = Enum.map(option_names, &String.split(&1, "."))

    split_names
    |> Enum.zip_reduce([], fn segments, acc ->
      segment = hd(segments)

      if Enum.all?(segments, &(&1 == segment)) do
        [segment | acc]
      else
        acc
      end
    end)
    |> Enum.reverse()
    |> case do
      [] -> hd(option_names)
      parts -> Enum.join(parts, ".")
    end
  end

  # Group options by declaration path and compute display names.
  # Returns {module_records, option_to_declaration_map}.
  defp derive_modules(options_map) do
    # Group option names by their declaration (first declaration, or synthetic prefix)
    options_by_declaration =
      Enum.reduce(options_map, %{}, fn {name, entry}, acc ->
        declaration = resolve_declaration(name, entry["declarations"] || [])

        Map.update(acc, declaration, [name], &[name | &1])
      end)

    module_records =
      Enum.map(options_by_declaration, fn {declaration, option_names} ->
        %{
          declaration: declaration,
          display_name: display_name_for_options(option_names)
        }
      end)

    option_to_declaration =
      Enum.flat_map(options_by_declaration, fn {declaration, option_names} ->
        Enum.map(option_names, &{&1, declaration})
      end)
      |> Map.new()

    {module_records, option_to_declaration}
  end

  # Use first declaration path, or derive a synthetic one from the option name prefix
  defp resolve_declaration(_name, [first | _rest]), do: first

  defp resolve_declaration(name, []) do
    case String.split(name, ".") do
      [one] -> one
      parts -> parts |> Enum.take(2) |> Enum.join(".")
    end
  end

  defp extract_text(%{"text" => text}), do: text
  defp extract_text(_), do: nil

  defp detect_option_events(channel_revision) do
    {added, removed} =
      Tracker.Nixpkgs.OptionRevision.diff_option_ids(
        channel_revision.id,
        channel_revision.previous_channel_revision_id
      )

    events =
      Enum.map(added, fn option_id ->
        %{type: :added, option_id: option_id, channel_revision_id: channel_revision.id}
      end) ++
        Enum.map(removed, fn option_id ->
          %{type: :removed, option_id: option_id, channel_revision_id: channel_revision.id}
        end)

    Tracker.Nixpkgs.OptionEvent.bulk_create_all(events)
  end

  defp link_options_to_packages(options_map, option_id_map) do
    alias Tracker.Nixpkgs.OptionPackageLinker

    links = OptionPackageLinker.extract_links(options_map)

    # Collect unique attribute paths and batch lookup package IDs
    attr_paths = links |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    package_id_map =
      case attr_paths do
        [] ->
          %{}

        paths ->
          Tracker.Nixpkgs.Package.ids_by_attributes!(paths)
          |> Map.new(&{&1.attribute, &1.id})
      end

    # Build join records, skipping unresolved attributes
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
    |> Tracker.Nixpkgs.OptionPackage.bulk_create_all()
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

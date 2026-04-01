defmodule Tracker.Nixpkgs.OptionsWorker do
  use Oban.Worker, queue: :channels, max_attempts: 10

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"channel" => channel, "base_url" => base_url, "revision" => revision}
      }) do
    case Tracker.Nixpkgs.ChannelRevision.find(channel, revision) do
      {:ok, %Tracker.Nixpkgs.ChannelRevision{result: :success} = channel_revision} ->
        fetch_options(base_url)
        |> write_to_database(channel_revision)

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

    # Step 5: Detect option events if there's a previous revision
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

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

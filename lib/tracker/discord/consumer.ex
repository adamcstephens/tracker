defmodule Tracker.Discord.Consumer do
  @moduledoc false

  use Nostrum.Consumer

  alias Nostrum.Api.{ApplicationCommand, Interaction}
  alias Tracker.Nixpkgs.{Channel, ChannelRevision, OptionSpan, Package, PackageSpan}

  require Logger

  def commands do
    [
      command("package", "Look up a package in Tracker"),
      command("nixos", "Look up a NixOS option in Tracker")
    ]
  end

  @impl true
  def handle_event({:READY, _, _}) do
    case ApplicationCommand.bulk_overwrite_global_commands(commands()) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.error("Failed to register Discord commands: #{inspect(reason)}")
    end
  end

  @impl true
  def handle_event({:INTERACTION_CREATE, %{data: %{name: command}} = interaction, _})
      when command in ["package", "nixos"] do
    {query, channel} = interaction_args(interaction)

    case Interaction.create_response(interaction, response_for(command, query, channel)) do
      {:ok} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to respond to Discord interaction: #{inspect(reason)}")
    end
  end

  def response_for("package", query, channel_name), do: package_response(query, channel_name)
  def response_for("nixos", query, channel_name), do: option_response(query, channel_name)

  defp package_response(query, channel_name) do
    with {:ok, channel, revision} <- resolve_channel(channel_name),
         {:ok, %{results: packages}} <- Package.list(query, channel.id, page: [limit: 5]),
         %{} = package <- Enum.find(packages, &(&1.attribute == query)),
         {:ok, package} <-
           Package.get_by_attribute(package.attribute, load: [:maintainers, :teams]),
         {:ok, [span]} <-
           PackageSpan.at_for_packages(channel.id, revision.released_at, [package.id]) do
      embed_response(package.attribute, span.description, [
        field("Version", span.version || "Unknown"),
        field("Availability", availability(span)),
        field("Channel", "#{channel.name} @ #{short_revision(revision.revision)}"),
        field(
          "Maintainers",
          package.maintainers
          |> Enum.map(& &1.github)
          |> Enum.reject(&is_nil/1)
          |> list_or_unknown()
        ),
        field("Teams", package.teams |> Enum.map(& &1.short_name) |> list_or_unknown()),
        tracker_link("/packages/#{URI.encode(package.attribute)}", channel, revision)
      ])
    else
      {:error, response} -> response
      _ -> package_matches(query, channel_name)
    end
  end

  defp option_response(query, channel_name) do
    with {:ok, channel, revision} <- resolve_channel(channel_name),
         {:ok, span} when not is_nil(span) <-
           OptionSpan.get_by_name_at(channel.id, revision.released_at, query) do
      embed_response(span.option.name, span.description, [
        field("Type", span.type || "Unknown"),
        field("Read-only", if(span.read_only, do: "Yes", else: "No")),
        field("Channel", "#{channel.name} @ #{short_revision(revision.revision)}"),
        tracker_link("/options/#{URI.encode(span.option.name)}", channel, revision)
      ])
    else
      {:ok, nil} -> option_matches(query, channel_name)
      {:error, response} -> response
      _ -> option_matches(query, channel_name)
    end
  end

  defp package_matches(query, channel_name) do
    with {:ok, channel, revision} <- resolve_channel(channel_name),
         {:ok, %{results: [_ | _] = packages}} <-
           Package.list(query, channel.id, page: [limit: 5]) do
      matches_response(:package, query, packages, & &1.attribute, "/packages/", channel, revision)
    else
      {:error, response} -> response
      _ -> not_found_response(query)
    end
  end

  defp option_matches(query, channel_name) do
    with {:ok, channel, revision} <- resolve_channel(channel_name),
         {:ok, %{results: [_ | _] = spans}} <-
           OptionSpan.list_by_channel(channel.id, revision.released_at, query, "",
             page: [limit: 5]
           ) do
      matches_response(:option, query, spans, & &1.option.name, "/options/", channel, revision)
    else
      {:error, response} -> response
      _ -> not_found_response(query)
    end
  end

  defp resolve_channel(nil), do: resolve_channel("nixos-unstable")
  defp resolve_channel(""), do: resolve_channel("nixos-unstable")

  defp resolve_channel(channel_name) do
    case Channel.by_name(channel_name) do
      {:ok, %{status: :retired}} ->
        {:error, message_response("Channel `#{escape_inline(channel_name)}` is retired.")}

      {:ok, channel} ->
        case ChannelRevision.latest_at(channel.id) do
          {:ok, revision} ->
            {:ok, channel, revision}

          _ ->
            {:error,
             message_response(
               "Channel `#{escape_inline(channel_name)}` has no revision data yet."
             )}
        end

      _ ->
        {:error, message_response("Unknown channel `#{escape_inline(channel_name)}`.")}
    end
  end

  defp matches_response(kind, query, records, name, path, channel, revision) do
    links =
      Enum.map(records, fn record ->
        "[#{escape_inline(name.(record))}](#{tracker_url(path <> URI.encode(name.(record)), channel, revision)})"
      end)

    message_response(
      Enum.join(["Several #{kind} results match `#{escape_inline(query)}`:", "" | links], "\n")
    )
  end

  defp not_found_response(query),
    do: message_response("No result found for `#{escape_inline(query)}`.")

  defp embed_response(title, description, fields),
    do:
      response(%{
        embeds: [
          %{
            title: escape(title),
            description: description && description |> escape() |> truncate(1_024),
            fields: fields
          }
        ]
      })

  defp message_response(message), do: response(%{content: message})
  defp response(data), do: %{type: 4, data: Map.put(data, :flags, 64)}
  defp field(name, value), do: %{name: name, value: escape(value), inline: true}

  defp tracker_link(path, channel, revision),
    do: %{name: "Tracker", value: "[Open in Tracker](#{tracker_url(path, channel, revision)})"}

  defp tracker_url(path, channel, revision),
    do:
      TrackerWeb.Endpoint.url() <>
        path <> "?channel=#{URI.encode_www_form(channel.name)}&rev=#{revision.revision}"

  defp availability(span) do
    case Enum.filter([:broken, :unfree, :insecure, :unsupported], &Map.get(span, &1)) do
      [] -> "Available"
      flags -> Enum.map_join(flags, ", ", &Atom.to_string/1)
    end
  end

  defp list_or_unknown([]), do: "Unknown"
  defp list_or_unknown(items), do: Enum.join(items, ", ")
  defp short_revision(revision), do: String.slice(revision, 0, 7)
  defp escape_inline(value), do: value |> escape() |> String.replace("`", "\\`")

  defp escape(value),
    do:
      value
      |> to_string()
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")

  defp truncate(value, limit) when byte_size(value) <= limit, do: value
  defp truncate(value, limit), do: String.slice(value, 0, limit - 3) <> "..."

  defp command(name, description) do
    %{
      name: name,
      description: description,
      options: [
        %{
          name: "search_term",
          description: "Package attribute or option name",
          type: 3,
          required: true
        },
        %{
          name: "channel",
          description: "NixOS channel (default: nixos-unstable)",
          type: 3,
          required: false
        }
      ]
    }
  end

  defp interaction_args(%{data: %{options: options}}) do
    {option_value(options, "search_term"), option_value(options, "channel")}
  end

  defp interaction_args(_), do: {"", nil}

  defp option_value(options, name) do
    case Enum.find(options || [], &(&1.name == name)) do
      %{value: value} when is_binary(value) -> value
      _ -> nil
    end
  end
end

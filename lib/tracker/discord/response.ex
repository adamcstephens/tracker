defmodule Tracker.Discord.Response do
  @moduledoc false

  alias Tracker.Discord.Lookup

  @ephemeral 64
  @description_limit 1_024

  def render({:ok, %Lookup.Package{} = package}) do
    embed(package.attribute, package.description, package_fields(package))
  end

  def render({:ok, %Lookup.Option{} = option}) do
    fields = [
      field("Type", option.type || "Unknown"),
      field("Read-only", if(option.read_only, do: "Yes", else: "No")),
      field("Channel", "#{option.channel} @ #{short_revision(option.revision)}"),
      tracker_link(option.url)
    ]

    embed(option.name, option.description, fields)
  end

  def render({:ok, %Lookup.Matches{} = matches}) do
    content =
      ["Several #{matches.kind} results match `#{escape_inline(matches.query)}`:", ""] ++
        Enum.map(matches.items, &"[#{escape_inline(&1.name)}](#{&1.url})")

    response(%{content: Enum.join(content, "\n")})
  end

  def render({:error, %Lookup.Error{reason: :not_found, query: query}}) do
    response(%{content: "No result found for `#{escape_inline(query)}`."})
  end

  def render({:error, %Lookup.Error{reason: reason, channel: channel}}) do
    message =
      case reason do
        :unknown_channel -> "Unknown channel `#{escape_inline(channel)}`."
        :retired_channel -> "Channel `#{escape_inline(channel)}` is retired."
        :no_data -> "Channel `#{escape_inline(channel)}` has no revision data yet."
      end

    response(%{content: message})
  end

  defp embed(title, description, fields) do
    response(%{
      embeds: [
        %{
          title: escape(title),
          description: description && description |> escape() |> truncate(@description_limit),
          fields: fields
        }
      ]
    })
  end

  defp package_fields(package) do
    availability =
      [:broken, :unfree, :insecure, :unsupported]
      |> Enum.filter(&Map.get(package, &1))
      |> Enum.map_join(", ", &Atom.to_string/1)
      |> case do
        "" -> "Available"
        flags -> flags
      end

    [
      field("Version", package.version || "Unknown"),
      field("Availability", availability),
      field("Channel", "#{package.channel} @ #{short_revision(package.revision)}"),
      field("Maintainers", list_or_unknown(package.maintainers)),
      field("Teams", list_or_unknown(package.teams)),
      tracker_link(package.url)
    ]
  end

  defp response(data), do: %{type: 4, data: Map.put(data, :flags, @ephemeral)}
  defp field(name, value), do: %{name: name, value: escape(value), inline: true}
  defp tracker_link(url), do: %{name: "Tracker", value: "[Open in Tracker](#{url})"}
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
end

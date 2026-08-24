defmodule Tracker.Discord.Consumer do
  @moduledoc false

  use Nostrum.Consumer

  alias Nostrum.Api.{ApplicationCommand, Interaction}
  alias Tracker.Discord.{Lookup, Response}

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

    result =
      case command do
        "package" -> Lookup.package(query, channel)
        "nixos" -> Lookup.option(query, channel)
      end

    case Interaction.create_response(interaction, Response.render(result)) do
      {:ok} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to respond to Discord interaction: #{inspect(reason)}")
    end
  end

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

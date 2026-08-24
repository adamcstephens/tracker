defmodule Tracker.Discord.Lookup do
  @moduledoc """
  Channel-revision-aware data for Discord lookup commands.
  """

  alias Tracker.Nixpkgs.{Channel, ChannelRevision, OptionSpan, PackageSpan}
  alias Tracker.Nixpkgs.Package, as: PackageResource

  @default_channel "nixos-unstable"

  defmodule Package do
    use TypedStruct

    typedstruct enforce: true do
      field :attribute, String.t()
      field :version, String.t() | nil
      field :description, String.t() | nil
      field :broken, boolean() | nil
      field :unfree, boolean() | nil
      field :insecure, boolean() | nil
      field :unsupported, boolean() | nil
      field :maintainers, [String.t()]
      field :teams, [String.t()]
      field :channel, String.t()
      field :revision, String.t()
      field :url, String.t()
    end
  end

  defmodule Option do
    use TypedStruct

    typedstruct enforce: true do
      field :name, String.t()
      field :type, String.t() | nil
      field :description, String.t() | nil
      field :read_only, boolean()
      field :channel, String.t()
      field :revision, String.t()
      field :url, String.t()
    end
  end

  defmodule Error do
    use TypedStruct

    typedstruct enforce: true do
      field :reason, :unknown_channel | :retired_channel | :no_data | :not_found
      field :query, String.t() | nil
      field :channel, String.t() | nil
    end
  end

  defmodule Match do
    use TypedStruct

    typedstruct enforce: true do
      field :name, String.t()
      field :url, String.t()
    end
  end

  defmodule Matches do
    use TypedStruct

    typedstruct enforce: true do
      field :kind, :package | :option
      field :query, String.t()
      field :items, [Match.t()]
    end
  end

  @spec package(String.t(), String.t() | nil) ::
          {:ok, Package.t() | Matches.t()} | {:error, Error.t()}
  def package(query, channel_name \\ nil) when is_binary(query) do
    case resolve_channel(channel_name) do
      {:ok, channel, revision} -> lookup_package(query, channel, revision)
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  @spec option(String.t(), String.t() | nil) ::
          {:ok, Option.t() | Matches.t()} | {:error, Error.t()}
  def option(query, channel_name \\ nil) when is_binary(query) do
    case resolve_channel(channel_name) do
      {:ok, channel, revision} -> lookup_option(query, channel, revision)
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp resolve_channel(nil), do: resolve_channel(@default_channel)
  defp resolve_channel(""), do: resolve_channel(@default_channel)

  defp resolve_channel(channel_name) do
    case Channel.by_name(channel_name) do
      {:ok, %{status: :retired}} ->
        {:error, %Error{reason: :retired_channel, query: nil, channel: channel_name}}

      {:ok, channel} ->
        case ChannelRevision.latest_at(channel.id) do
          {:ok, revision} -> {:ok, channel, revision}
          _ -> {:error, %Error{reason: :no_data, query: nil, channel: channel_name}}
        end

      _ ->
        {:error, %Error{reason: :unknown_channel, query: nil, channel: channel_name}}
    end
  end

  defp exact_package(query, channel_id, at) do
    case PackageResource.get_by_attribute(query, load: [:maintainers, :teams]) do
      {:ok, package} ->
        case package_span(package.id, channel_id, at) do
          {:ok, _span} -> {:ok, package}
          :error -> {:error, not_found(query)}
        end

      _ ->
        package_matches_for(query, channel_id)
    end
  end

  defp lookup_package(query, channel, revision) do
    with {:ok, package} <- exact_package(query, channel.id, revision.released_at),
         {:ok, span} <- package_span(package.id, channel.id, revision.released_at) do
      {:ok,
       %Package{
         attribute: package.attribute,
         version: span.version,
         description: span.description,
         broken: span.broken,
         unfree: span.unfree,
         insecure: span.insecure,
         unsupported: span.unsupported,
         maintainers: package.maintainers |> Enum.map(& &1.github) |> Enum.reject(&is_nil/1),
         teams: Enum.map(package.teams, & &1.short_name),
         channel: channel.name,
         revision: revision.revision,
         url: url("/packages/#{URI.encode(package.attribute)}", channel.name, revision.revision)
       }}
    else
      {:matches, packages} -> {:ok, package_matches(query, packages, channel, revision)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp package_matches_for(query, channel_id) do
    case PackageResource.list(query, channel_id, page: [limit: 5]) do
      {:ok, %{results: []}} -> {:error, not_found(query)}
      {:ok, %{results: packages}} -> {:matches, packages}
      _ -> {:error, not_found(query)}
    end
  end

  defp package_matches(query, packages, channel, revision) do
    %Matches{
      kind: :package,
      query: query,
      items:
        Enum.map(packages, fn package ->
          %Match{
            name: package.attribute,
            url:
              url("/packages/#{URI.encode(package.attribute)}", channel.name, revision.revision)
          }
        end)
    }
  end

  defp package_span(package_id, channel_id, at) do
    case PackageSpan.at_for_packages(channel_id, at, [package_id]) do
      {:ok, [span]} -> {:ok, span}
      _ -> :error
    end
  end

  defp exact_option(query, channel_id, at) do
    case OptionSpan.list_by_channel(channel_id, at, query, "", page: [limit: 15]) do
      {:ok, page} ->
        case Enum.find(page.results, &(&1.option.name == query)) do
          nil -> option_matches_for(query, channel_id, at)
          span -> {:ok, span}
        end

      _ ->
        {:error, not_found(query)}
    end
  end

  defp lookup_option(query, channel, revision) do
    with {:ok, span} <- exact_option(query, channel.id, revision.released_at) do
      {:ok,
       %Option{
         name: span.option.name,
         type: span.type,
         description: span.description,
         read_only: span.read_only,
         channel: channel.name,
         revision: revision.revision,
         url: url("/options/#{URI.encode(span.option.name)}", channel.name, revision.revision)
       }}
    else
      {:matches, spans} -> {:ok, option_matches(query, spans, channel, revision)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp option_matches_for(query, channel_id, at) do
    case OptionSpan.list_by_channel(channel_id, at, query, "", page: [limit: 5]) do
      {:ok, %{results: []}} -> {:error, not_found(query)}
      {:ok, %{results: spans}} -> {:matches, spans}
      _ -> {:error, not_found(query)}
    end
  end

  defp option_matches(query, spans, channel, revision) do
    %Matches{
      kind: :option,
      query: query,
      items:
        Enum.map(spans, fn span ->
          %Match{
            name: span.option.name,
            url: url("/options/#{URI.encode(span.option.name)}", channel.name, revision.revision)
          }
        end)
    }
  end

  defp not_found(query), do: %Error{reason: :not_found, query: query, channel: nil}

  defp url(path, channel, revision) do
    TrackerWeb.Endpoint.url() <>
      path <> "?channel=#{URI.encode_www_form(channel)}&rev=#{revision}"
  end
end

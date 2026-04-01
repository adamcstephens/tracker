defmodule Tracker.Nixpkgs.OptionPackageLinker do
  @moduledoc """
  Extracts Option-to-Package links from options metadata using three signals:

  1. `type == "package"` with `pkgs.ATTR` default (highest volume)
  2. `type == "package"` with complex/missing default (scan for pkgs.X references)
  3. `relatedPackages` markdown field (parse pkgs.ATTR and search.nixos.org URLs)
  """

  @pkgs_attr_regex ~r/pkgs\.([a-zA-Z0-9_][a-zA-Z0-9_.-]*)/
  @show_param_regex ~r/show=([a-zA-Z0-9_][a-zA-Z0-9_.-]*)/

  @doc """
  Extracts `{option_name, attribute_path}` pairs from an options map.

  The options map is keyed by option name, with values containing at minimum
  `"type"` and optionally `"default"` and `"relatedPackages"`.

  Returns a deduplicated list of `{option_name, attribute_path}` tuples.
  """
  def extract_links(options_map) do
    options_map
    |> Enum.flat_map(fn {name, entry} ->
      package_links(name, entry) ++ related_package_links(name, entry)
    end)
    |> Enum.uniq()
  end

  # Signals 1 & 2: type == "package" options
  defp package_links(name, %{"type" => "package", "default" => default}) do
    case extract_text(default) do
      nil -> []
      text -> extract_pkgs_attrs(text) |> Enum.map(&{name, &1})
    end
  end

  defp package_links(_name, _entry), do: []

  defp extract_text(%{"text" => text}) when is_binary(text), do: text
  defp extract_text(text) when is_binary(text), do: text
  defp extract_text(_), do: nil

  # Signal 3: relatedPackages field (any option type)
  defp related_package_links(name, %{"relatedPackages" => text}) when is_binary(text) do
    pkgs = extract_pkgs_attrs(text)
    show_params = extract_show_params(text)

    (pkgs ++ show_params)
    |> Enum.uniq()
    |> Enum.map(&{name, &1})
  end

  defp related_package_links(_name, _entry), do: []

  defp extract_pkgs_attrs(text) do
    Regex.scan(@pkgs_attr_regex, text)
    |> Enum.map(fn [_, attr] -> attr end)
  end

  defp extract_show_params(text) do
    Regex.scan(@show_param_regex, text)
    |> Enum.map(fn [_, attr] -> attr end)
  end
end

defmodule Tracker.Nixpkgs.UpdateLogKey do
  @moduledoc "Matching identity for discovered nixpkgs update-log directories."

  alias Tracker.Nixpkgs.PackageSetMapping

  def for_attribute(attribute) do
    parsed = PackageSetMapping.parse(attribute)

    case parsed.package_set do
      nil ->
        {":top-level", normalize(attribute)}

      prefix ->
        namespace = if parsed.ecosystem == "", do: prefix, else: parsed.ecosystem
        {namespace, normalize(parsed.family_name)}
    end
  end

  defp normalize(name), do: Regex.replace(~r/(?:-full|Full|-minimal|Minimal)$/, name, "")
end

defmodule Tracker.Nixpkgs.PackageSetMapping do
  @moduledoc """
  Parses nixpkgs attribute paths into package set, version, family, and ecosystem components.

  Given an attribute like `python313Packages.numpy`, returns:
    %{package_set: "python313Packages", set_version: "3.13", family_name: "numpy", ecosystem: "python"}
  """

  @no_family %{package_set: nil, set_version: nil, family_name: nil, ecosystem: nil}

  @doc """
  Parses a nixpkgs attribute into its package set components.

  Returns a map with:
  - `package_set` - the full set prefix (e.g., "python313Packages"), nil for top-level
  - `set_version` - parsed version string, nil if not versioned
  - `family_name` - the package name within the set, nil if no family
  - `ecosystem` - the ecosystem name (e.g., "python"), nil if no family
  """
  @spec parse(String.t()) :: %{
          package_set: String.t() | nil,
          set_version: String.t() | nil,
          family_name: String.t() | nil,
          ecosystem: String.t() | nil
        }
  def parse(attribute) do
    case String.split(attribute, ".", parts: 2) do
      [prefix, name] -> parse_dotted(prefix, name)
      [_undotted] -> parse_toplevel(attribute)
    end
  end

  defp parse_dotted(prefix, name) do
    case match_set_pattern(prefix) do
      {:ok, ecosystem, version} ->
        %{package_set: prefix, set_version: version, family_name: name, ecosystem: ecosystem}

      :no_match ->
        %{package_set: prefix, set_version: nil, family_name: name, ecosystem: ""}
    end
  end

  # Python: python311Packages → python 3.11
  defp match_set_pattern("python" <> rest) do
    cond do
      match = Regex.run(~r/^(\d)(\d+)Packages$/, rest) ->
        [_, maj, min] = match
        {:ok, "python", "#{maj}.#{min}"}

      true ->
        :no_match
    end
  end

  # Perl: perl540Packages → perl 5.40; perlPackages → perl
  defp match_set_pattern("perl" <> rest) do
    cond do
      match = Regex.run(~r/^(\d)(\d+)Packages$/, rest) ->
        [_, maj, min] = match
        {:ok, "perl", "#{maj}.#{min}"}

      rest =~ ~r/^\d*Packages$/ ->
        {:ok, "perl", nil}

      true ->
        :no_match
    end
  end

  # Ruby: rubyPackages_3_4 → ruby 3.4
  defp match_set_pattern("rubyPackages" <> rest) do
    case Regex.run(~r/^_(\d+(?:_\d+)+)$/, rest) do
      [_, v] -> {:ok, "ruby", String.replace(v, "_", ".")}
      nil when rest == "" -> {:ok, "ruby", nil}
      _ -> :no_match
    end
  end

  # OCaml: ocamlPackages_latest → ocaml latest
  defp match_set_pattern("ocamlPackages" <> rest) do
    case rest do
      "_latest" -> {:ok, "ocaml", "latest"}
      "" -> {:ok, "ocaml", nil}
      _ -> :no_match
    end
  end

  # Beam: beamMinimal26Packages → beam 26-minimal; beam27Packages → beam 27
  defp match_set_pattern("beam" <> rest) do
    cond do
      match = Regex.run(~r/^Minimal(\d+)Packages$/, rest) ->
        [_, v] = match
        {:ok, "beam", "#{v}-minimal"}

      match = Regex.run(~r/^(\d+)Packages$/, rest) ->
        [_, v] = match
        {:ok, "beam", v}

      true ->
        :no_match
    end
  end

  # Linux: linuxPackages_zen → linux zen
  defp match_set_pattern("linuxPackages" <> rest) do
    case Regex.run(~r/^_(\w+)$/, rest) do
      [_, v] -> {:ok, "linux", v}
      nil when rest == "" -> {:ok, "linux", nil}
      _ -> :no_match
    end
  end

  # LLVM: llvmPackages_18 → llvm 18
  defp match_set_pattern("llvmPackages_" <> v) when v != "" do
    if v =~ ~r/^\d+$/, do: {:ok, "llvm", v}, else: :no_match
  end

  # CUDA: cudaPackages_11 → cuda 11
  defp match_set_pattern("cudaPackages" <> rest) do
    case Regex.run(~r/^_(\d+)$/, rest) do
      [_, v] -> {:ok, "cuda", v}
      nil when rest == "" -> {:ok, "cuda", nil}
      _ -> :no_match
    end
  end

  # Godot: godotPackages_4_4 → godot 4.4
  defp match_set_pattern("godotPackages_" <> rest) do
    case Regex.run(~r/^(\d+(?:_\d+)*)$/, rest) do
      [_, v] -> {:ok, "godot", String.replace(v, "_", ".")}
      _ -> :no_match
    end
  end

  # Zabbix: zabbix72 → zabbix 72
  defp match_set_pattern("zabbix" <> v) when v != "" do
    if v =~ ~r/^\d+$/, do: {:ok, "zabbix", v}, else: :no_match
  end

  # Qt: qt6 → qt 6
  defp match_set_pattern("qt" <> v) when byte_size(v) == 1 do
    if v =~ ~r/^\d$/, do: {:ok, "qt", v}, else: :no_match
  end

  # Chicken: chickenPackages_5 → chicken 5
  defp match_set_pattern("chickenPackages_" <> v) do
    if v =~ ~r/^\d+$/, do: {:ok, "chicken", v}, else: :no_match
  end

  # Factor: factorPackages-0_99 → factor 0.99
  defp match_set_pattern("factorPackages-" <> rest) do
    case Regex.run(~r/^(\d+_\d+)$/, rest) do
      [_, v] -> {:ok, "factor", String.replace(v, "_", ".")}
      _ -> :no_match
    end
  end

  # PHP: php83Packages → php 8.3; php83Extensions → php-extensions 8.3
  defp match_set_pattern("php" <> rest) do
    cond do
      match = Regex.run(~r/^(\d)(\d+)Packages$/, rest) ->
        [_, maj, min] = match
        {:ok, "php", "#{maj}.#{min}"}

      match = Regex.run(~r/^(\d)(\d+)Extensions$/, rest) ->
        [_, maj, min] = match
        {:ok, "php-extensions", "#{maj}.#{min}"}

      rest == "Packages" ->
        {:ok, "php", nil}

      rest == "Extensions" ->
        {:ok, "php-extensions", nil}

      true ->
        :no_match
    end
  end

  # Lua: lua53Packages → lua 5.3; luaPackages → lua
  defp match_set_pattern("lua" <> rest) do
    cond do
      match = Regex.run(~r/^(\d)(\d+)Packages$/, rest) ->
        [_, maj, min] = match
        {:ok, "lua", "#{maj}.#{min}"}

      rest == "Packages" ->
        {:ok, "lua", nil}

      true ->
        :no_match
    end
  end

  # Single-set ecosystems
  defp match_set_pattern("haskellPackages"), do: {:ok, "haskell", nil}
  defp match_set_pattern("emacsPackages"), do: {:ok, "emacs", nil}
  defp match_set_pattern("rPackages"), do: {:ok, "r", nil}
  defp match_set_pattern("texlivePackages"), do: {:ok, "texlive", nil}
  defp match_set_pattern("typstPackages"), do: {:ok, "typst", nil}
  defp match_set_pattern("sbclPackages"), do: {:ok, "sbcl", nil}
  defp match_set_pattern("vimPlugins"), do: {:ok, "vim", nil}
  defp match_set_pattern("gnomeExtensions"), do: {:ok, "gnome-extensions", nil}
  defp match_set_pattern("vscode-extensions"), do: {:ok, "vscode", nil}

  defp match_set_pattern(_), do: :no_match

  # Top-level patterns for runtime packages
  defp parse_toplevel(attribute) do
    cond do
      match = Regex.run(~r/^python(\d)(\d+)$/, attribute) ->
        [_, maj, min] = match

        %{
          package_set: nil,
          set_version: "#{maj}.#{min}",
          family_name: "python",
          ecosystem: "python"
        }

      match = Regex.run(~r/^elixir_(\d+)_(\d+)$/, attribute) ->
        [_, maj, min] = match

        %{
          package_set: nil,
          set_version: "#{maj}.#{min}",
          family_name: "elixir",
          ecosystem: "beam"
        }

      match = Regex.run(~r/^erlang_(\d+)$/, attribute) ->
        [_, v] = match
        %{package_set: nil, set_version: v, family_name: "erlang", ecosystem: "beam"}

      true ->
        @no_family
    end
  end
end

defmodule TrackerWeb.Layouts do
  @moduledoc """
  This module holds different layouts used by your application.

  See the `layouts` directory for all templates available.
  The "root" layout is a skeleton rendered as part of the
  application router. The "app" layout is set as the default
  layout on both `use TrackerWeb, :controller` and
  `use TrackerWeb, :live_view`.
  """
  use TrackerWeb, :html

  embed_templates "layouts/*"

  def active_nav?(view, prefix) when is_atom(view) do
    case Module.split(view) do
      [_, ^prefix | _] -> true
      _ -> false
    end
  end

  def active_nav?(_view, _prefix), do: false

  @doc """
  Returns up to two uppercase initials for a given name, used as the
  monogram in the user chip avatar when a GitHub avatar is unavailable.
  """
  def monogram(name) when is_binary(name) and byte_size(name) > 0 do
    name
    |> String.graphemes()
    |> Enum.take(2)
    |> Enum.map_join("", &String.upcase/1)
  end

  def monogram(_), do: ""

  @doc """
  Decorates a chrome navigation path with the persisted `?search=` param
  so the global search query carries across section navigations.
  """
  def nav_path(path, ""), do: path
  def nav_path(path, nil), do: path

  def nav_path(path, search) when is_binary(search) do
    "#{path}?#{URI.encode_query(%{search: search})}"
  end
end

defmodule Tracker.Ingestion.Helpers do
  @moduledoc """
  Shared helper functions for ingestion step modules.
  """

  @doc """
  Conditionally puts a key-value pair into a map.

  Returns the map unchanged if the value is nil, otherwise
  adds the key-value pair.
  """
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)
end

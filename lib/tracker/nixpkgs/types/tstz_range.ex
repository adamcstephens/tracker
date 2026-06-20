defmodule Tracker.Nixpkgs.Types.TstzRange do
  @moduledoc """
  Ash type for a Postgres `tstzrange` column, represented as a `%Postgrex.Range{}`.

  Spans use a half-open `[from, to)` validity interval over
  `channel_revisions.released_at`. An unbounded upper (`upper_inf/1`) marks the
  currently-open span. Postgrex encodes/decodes `tstzrange` to `Postgrex.Range`
  natively, so casting here is pass-through.
  """
  use Ash.Type

  @impl true
  def storage_type(_constraints), do: :tstzrange

  @impl true
  def cast_input(nil, _constraints), do: {:ok, nil}
  def cast_input(%Postgrex.Range{} = range, _constraints), do: {:ok, range}
  def cast_input(_other, _constraints), do: :error

  @impl true
  def cast_stored(nil, _constraints), do: {:ok, nil}
  def cast_stored(%Postgrex.Range{} = range, _constraints), do: {:ok, range}
  def cast_stored(_other, _constraints), do: :error

  @impl true
  def dump_to_native(nil, _constraints), do: {:ok, nil}
  def dump_to_native(%Postgrex.Range{} = range, _constraints), do: {:ok, range}
  def dump_to_native(_other, _constraints), do: :error

  # Supports closing a span via an atomic expression update
  # (`tstzrange(lower(valid), closed_at)`); the fragment already yields a
  # tstzrange, so pass it through unchanged.
  @impl true
  def cast_atomic(expr, _constraints), do: {:atomic, expr}
end

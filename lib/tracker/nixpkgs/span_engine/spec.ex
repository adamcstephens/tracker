defmodule Tracker.Nixpkgs.SpanEngine.Spec do
  @moduledoc """
  Per-domain configuration that lets `Tracker.Nixpkgs.SpanEngine` drive any span
  table (packages, options, option↔file) unchanged.

  * `resource` — the span Ash resource (must expose `:open_for_channel`, `:at`,
    `:close`; the engine inserts opens directly via `Repo.insert_all`).
  * `key_columns` — identity beyond `channel_id` (e.g. `[:package_id]`,
    `[:option_id, :file_id]`).
  * `payload_columns` — the fingerprinted, reconstructable fields (`[]` for
    membership-only option↔file spans).
  * `key_fn` — operates on both incoming item maps and loaded span records (both
    expose the key columns as keys).
  * `fingerprint_fn` — operates on incoming item maps only. Spans carry their
    fingerprint in a stored column, written when the span opens, so the engine
    never recomputes one from a loaded record.
  """
  use TypedStruct

  typedstruct enforce: true do
    field :resource, module()
    field :key_columns, [atom()]
    field :payload_columns, [atom()]
    field :key_fn, (map() -> term())
    field :fingerprint_fn, (map() -> term())
  end

  @spec new(keyword()) :: t()
  def new(opts) do
    key_columns = Keyword.fetch!(opts, :key_columns)
    payload_columns = Keyword.fetch!(opts, :payload_columns)

    %__MODULE__{
      resource: Keyword.fetch!(opts, :resource),
      key_columns: key_columns,
      payload_columns: payload_columns,
      key_fn:
        Keyword.get(opts, :key_fn, &Enum.map(key_columns, fn col -> Map.fetch!(&1, col) end)),
      fingerprint_fn:
        Keyword.get(opts, :fingerprint_fn, fn item -> fingerprint(payload_columns, item) end)
    }
  end

  @doc """
  Hashes an item's payload for comparison against a span's stored fingerprint.

  Hashes a *list* in `payload_columns` order rather than a map, so the encoding
  carries no map-ordering ambiguity. Changing that list changes every
  fingerprint, which reopens every span — the same churn a payload change has
  always caused.
  """
  @spec fingerprint([atom()], map()) :: binary()
  def fingerprint(payload_columns, item) do
    payload_columns
    |> Enum.map(&Map.fetch!(item, &1))
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
  end
end

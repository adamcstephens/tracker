defmodule Tracker.Nixpkgs.SpanEngine.Spec do
  @moduledoc """
  Per-domain configuration that lets `Tracker.Nixpkgs.SpanEngine` drive any span
  table (packages, options, option↔file) unchanged.

  * `resource` — the span Ash resource (must expose `:open_for_channel`, `:at`,
    `:open`, `:close`).
  * `key_columns` — identity beyond `channel_id` (e.g. `[:package_id]`,
    `[:option_id, :file_id]`).
  * `payload_columns` — the fingerprinted, reconstructable fields (`[]` for
    membership-only option↔file spans).
  * `key_fn` / `fingerprint_fn` — operate on both incoming item maps and loaded
    span records (both expose the columns as keys). Defaults derive from the
    column lists; options can pass a hashing `fingerprint_fn`.
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
        Keyword.get(
          opts,
          :fingerprint_fn,
          &Map.new(payload_columns, fn col -> {col, Map.fetch!(&1, col)} end)
        )
    }
  end
end

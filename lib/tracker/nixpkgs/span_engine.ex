defmodule Tracker.Nixpkgs.SpanEngine do
  @moduledoc """
  Domain-agnostic core that folds revision snapshots into validity-interval
  ("span") rows — one row per *change* rather than one per revision.

  For a revision at `released_at` T, each incoming item either opens a new span
  (newly-seen key), is left untouched (same fingerprint), or closes the open
  span at T and reopens a disjoint one (changed fingerprint). When the revision
  is *complete*, any open span whose key is absent is closed (removal). Spans are
  half-open `[from, to)` over `released_at`, scoped per channel; the `btree_gist`
  EXCLUDE constraint guarantees non-overlap.

  Parameterised by `Tracker.Nixpkgs.SpanEngine.Spec` so packages, options, and
  option↔file membership all reuse it unchanged.
  """
  require Ash.Query

  alias Tracker.Nixpkgs.SpanEngine.Spec

  @doc """
  Applies one revision's `incoming` set to the channel's spans at `released_at`.

  `incoming` is a list of maps carrying the spec's key + payload columns.
  `opts[:complete?]` (default `true`) gates removals — incomplete revisions
  (partial_success/error) never close absent keys. Returns
  `%{added, changed, removed, left}` counts.
  """
  @spec diff_and_apply(Spec.t(), integer(), DateTime.t(), [map()], keyword()) :: %{
          added: non_neg_integer(),
          changed: non_neg_integer(),
          removed: non_neg_integer(),
          left: non_neg_integer()
        }
  def diff_and_apply(%Spec{} = spec, channel_id, released_at, incoming, opts \\ []) do
    complete? = Keyword.get(opts, :complete?, true)

    open_by_key = Map.new(load_open(spec, channel_id), &{spec.key_fn.(&1), &1})
    incoming_by_key = Map.new(incoming, &{spec.key_fn.(&1), &1})

    {to_open, changed_ids, left} =
      Enum.reduce(incoming_by_key, {[], [], 0}, fn {key, item}, {opens, closes, left} ->
        case Map.get(open_by_key, key) do
          nil ->
            {[item | opens], closes, left}

          span ->
            if spec.fingerprint_fn.(item) == spec.fingerprint_fn.(span) do
              {opens, closes, left + 1}
            else
              {[item | opens], [span.id | closes], left}
            end
        end
      end)

    removed_ids =
      if complete? do
        for {key, span} <- open_by_key, not Map.has_key?(incoming_by_key, key), do: span.id
      else
        []
      end

    # One transaction per revision: a mid-revision failure rolls back the whole
    # revision rather than leaving spans half-applied. Close before open —
    # reopening at T while the prior span is still unbounded would overlap and
    # trip the EXCLUDE constraint.
    Tracker.Repo.transaction(fn ->
      close(spec, changed_ids ++ removed_ids, released_at)
      open(spec, channel_id, released_at, to_open)
    end)

    %{
      added: length(to_open) - length(changed_ids),
      changed: length(changed_ids),
      removed: length(removed_ids),
      left: left
    }
  end

  @doc """
  Folds an ascending-`released_at` enumerable of revisions through
  `diff_and_apply/5`. Each revision is `%{released_at:, incoming:, complete?:}`
  (`complete?` defaults to `true`). The primary ingestion path for both history
  and ongoing revisions.
  """
  @spec replay(Spec.t(), integer(), Enumerable.t()) :: :ok
  def replay(%Spec{} = spec, channel_id, revisions) do
    revisions
    |> Enum.sort_by(& &1.released_at, DateTime)
    |> Enum.each(fn rev ->
      diff_and_apply(spec, channel_id, rev.released_at, rev.incoming,
        complete?: Map.get(rev, :complete?, true)
      )
    end)
  end

  @doc """
  Point-in-time reconstruction: the `%{key => payload}` map of spans valid at
  `at` for the channel.
  """
  @spec reconstruct(Spec.t(), integer(), DateTime.t()) :: %{term() => map()}
  def reconstruct(%Spec{} = spec, channel_id, at) do
    spec.resource
    |> Ash.Query.for_read(:at, %{channel_id: channel_id, at: at})
    |> Ash.read!(authorize?: false)
    |> Map.new(&{spec.key_fn.(&1), payload(spec, &1)})
  end

  @doc """
  Verification oracle: asserts `reconstruct(spec, channel, at) == expected_set`,
  where `expected_set` is the `%{key => payload}` set parsed from the revision's
  source JSON. Returns `:ok` or `{:error, %{only_in_spans, only_in_source,
  payload_mismatch}}`.
  """
  @spec verify(Spec.t(), integer(), DateTime.t(), %{term() => map()}) ::
          :ok | {:error, map()}
  def verify(%Spec{} = spec, channel_id, at, expected) do
    actual = reconstruct(spec, channel_id, at)

    only_in_spans = Map.keys(actual) -- Map.keys(expected)
    only_in_source = Map.keys(expected) -- Map.keys(actual)

    payload_mismatch =
      for key <- Map.keys(actual),
          Map.has_key?(expected, key),
          actual[key] != expected[key],
          do: key

    if only_in_spans == [] and only_in_source == [] and payload_mismatch == [] do
      :ok
    else
      {:error,
       %{
         only_in_spans: only_in_spans,
         only_in_source: only_in_source,
         payload_mismatch: payload_mismatch
       }}
    end
  end

  defp load_open(spec, channel_id) do
    spec.resource
    |> Ash.Query.for_read(:open_for_channel, %{channel_id: channel_id})
    |> Ash.read!(authorize?: false)
  end

  defp close(_spec, [], _released_at), do: :ok

  defp close(spec, ids, released_at) do
    # Lock the closed rows in a deterministic (id) order. Defensive: spans are
    # per-channel (channel_id is in the key), so concurrent channels never touch
    # the same span rows — see trk-330.
    ids = Enum.sort(ids)

    spec.resource
    |> Ash.Query.filter(id in ^ids)
    |> Ash.bulk_update!(:close, %{closed_at: released_at},
      strategy: [:atomic],
      authorize?: false,
      return_errors?: true,
      return_records?: false
    )

    :ok
  end

  defp open(_spec, _channel_id, _released_at, []), do: :ok

  defp open(spec, channel_id, released_at, items) do
    range = %Postgrex.Range{
      lower: released_at,
      upper: :unbound,
      lower_inclusive: true,
      upper_inclusive: false
    }

    # Insert in a deterministic (key) order — defensive, as above (trk-330).
    records =
      items
      |> Enum.sort_by(spec.key_fn)
      |> Enum.map(fn item ->
        item
        |> Map.take(spec.key_columns ++ spec.payload_columns)
        |> Map.put(:channel_id, channel_id)
        |> Map.put(:valid, range)
      end)

    Ash.bulk_create!(records, spec.resource, :open,
      authorize?: false,
      return_errors?: true,
      return_records?: false
    )

    :ok
  end

  defp payload(spec, span), do: Map.new(spec.payload_columns, &{&1, Map.fetch!(span, &1)})
end

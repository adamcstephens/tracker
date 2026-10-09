defmodule Tracker.Nixpkgs.Preparations.RevisionComparison do
  @moduledoc "Filters identities to their net endpoint changes before pagination."

  use Ash.Resource.Preparation
  import Ash.Expr

  @impl Ash.Resource.Preparation
  def prepare(query, opts, _context) do
    from_channel_id = Ash.Query.get_argument(query, :from_channel_id)
    from_at = Ash.Query.get_argument(query, :from_at)
    to_channel_id = Ash.Query.get_argument(query, :to_channel_id)
    to_at = Ash.Query.get_argument(query, :to_at)
    change = Ash.Query.get_argument(query, :change)

    old = endpoint(from_channel_id, from_at)
    new = endpoint(to_channel_id, to_at)
    changed = changed(opts, from_channel_id, from_at, to_channel_id, to_at)

    filter =
      case change do
        "added" -> expr(not (^old) and ^new)
        "removed" -> expr(^old and not (^new))
        "changed" -> changed
        "all" -> expr((not (^old) and ^new) or (^old and not (^new)) or ^changed)
      end

    query
    |> Ash.Query.do_filter(candidates(Ash.Query.get_argument(query, :candidate_ids)))
    |> Ash.Query.do_filter(filter)
  end

  defp endpoint(channel, at) do
    expr(exists(spans, channel_id == ^channel and fragment("? @> ?::timestamptz", valid, ^at)))
  end

  defp changed(opts, from_channel, from_at, to_channel, to_at) do
    key = Ash.Expr.ref(Keyword.fetch!(opts, :key))

    difference =
      opts
      |> Keyword.fetch!(:fields)
      |> Enum.map(fn field ->
        reference = Ash.Expr.ref(field)
        expr(fragment("? IS DISTINCT FROM ?", ^reference, parent(^reference)))
      end)
      |> Enum.reduce(fn field, acc -> expr(^field or ^acc) end)

    counterpart = %Ash.Query.Exists{
      path: [],
      resource: Keyword.fetch!(opts, :span),
      related?: false,
      expr:
        expr(
          ^key == parent(^key) and channel_id == ^to_channel and
            fragment("? @> ?::timestamptz", valid, ^to_at) and ^difference
        )
    }

    expr(
      exists(
        spans,
        channel_id == ^from_channel and fragment("? @> ?::timestamptz", valid, ^from_at) and
          ^counterpart
      )
    )
  end

  defp candidates(nil), do: true
  defp candidates(ids), do: expr(id in ^ids)
end

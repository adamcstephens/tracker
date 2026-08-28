defmodule Tracker.Nixpkgs.Preparations.TrigramSearch do
  @moduledoc """
  Filters a read action by its `search` argument against the given fields.

  Matching goes through the `<<%` operator rather than a `strict_word_similarity`
  call so that the `gin_trgm_ops` indexes can serve it, which means the threshold
  comes from `pg_trgm.strict_word_similarity_threshold` instead of the query.

  Fields are attribute names, or `{path, name}` to reach through a relationship.
  """

  use Ash.Resource.Preparation

  @impl true
  def prepare(query, opts, _context) do
    search = query |> Ash.Query.get_argument(:search) |> to_string() |> String.trim()

    if search == "" do
      query
    else
      Ash.Query.do_filter(query, match(search, Keyword.fetch!(opts, :fields)))
    end
  end

  @doc "Builds the match expression on its own, for callers filtering per token."
  def match(search, fields) do
    fields
    |> Enum.flat_map(&arms(search, &1))
    |> Enum.reduce(&Ash.Expr.expr(^&1 or ^&2))
  end

  defp arms(search, field) do
    reference = reference(field)
    trigram = Ash.Expr.expr(fragment("? <<% ?", ^search, ^reference))

    # a pattern shorter than a trigram holds no index key, so an infix match on
    # it drags the whole disjunction into a sequential scan
    if String.length(search) < 3 do
      [trigram]
    else
      [trigram, Ash.Expr.expr(contains(^reference, ^Ash.CiString.new(search)))]
    end
  end

  defp reference({path, name}), do: Ash.Expr.ref(List.wrap(path), name)
  defp reference(name) when is_atom(name), do: Ash.Expr.ref(name)
end

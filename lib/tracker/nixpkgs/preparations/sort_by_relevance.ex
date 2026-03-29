defmodule Tracker.Nixpkgs.Preparations.SortByRelevance do
  use Ash.Resource.Preparation

  import Ash.Expr

  @impl true
  def prepare(query, _opts, _context) do
    search = Ash.Query.get_argument(query, :search)

    if search && to_string(search) != "" do
      query
      |> Ash.Query.sort([
        {calc(
           fragment(
             """
             CASE
               WHEN LOWER(?) = LOWER(?) THEN 0
               WHEN LOWER(?) LIKE LOWER(?) || '%' THEN 1
               WHEN LOWER(?) LIKE '%.' || LOWER(?) || '%' THEN 2
               ELSE 3
             END
             """,
             attribute,
             ^search,
             attribute,
             ^search,
             attribute,
             ^search
           ),
           type: :integer
         ), :asc},
        {calc(fragment("LENGTH(?)", attribute), type: :integer), :asc}
      ])
    else
      Ash.Query.sort(query, :attribute)
    end
  end
end

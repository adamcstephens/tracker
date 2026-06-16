defmodule GitHub.RateLimit do
  @moduledoc """
  GitHub rate limit endpoint.
  """

  alias GitHub.Client

  defmodule Resource do
    @moduledoc "Rate limit quota for a single resource (e.g. core, graphql)."
    use TypedStruct

    typedstruct do
      field :limit, integer()
      field :remaining, integer()
      field :reset, integer()
    end
  end

  @doc """
  Fetches the current rate limit, exposing the `core` (REST) and `graphql`
  resources under `:resources`.
  """
  @spec get(keyword()) :: {:ok, %{resources: map()}} | {:error, GitHub.Error.t()}
  def get(opts \\ []) do
    with {:ok, json} <- Client.get("/rate_limit", Client.to_request_opts(opts)) do
      resources = json["resources"] || %{}

      {:ok,
       %{
         resources: %{
           core: resource(resources["core"]),
           graphql: resource(resources["graphql"])
         }
       }}
    end
  end

  defp resource(nil), do: nil

  defp resource(map) when is_map(map) do
    %Resource{limit: map["limit"], remaining: map["remaining"], reset: map["reset"]}
  end
end

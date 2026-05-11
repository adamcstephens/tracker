defmodule Tracker.GitHub.GraphQL do
  @moduledoc """
  Batched GraphQL client for GitHub PR lookup.

  Uses the `nodes(ids: [...])` query to fetch up to 100 pull requests
  in a single request, which is far cheaper than per-PR REST calls.

  Requests are tracked against the `:graphql` bucket in
  `Tracker.GitHub.RateLimitCache`, independently of REST quota.
  """

  require Logger

  alias GitHub.Error
  alias Tracker.GitHub.GraphQL.PullRequest
  alias Tracker.GitHub.RateLimitCache

  @endpoint "https://api.github.com/graphql"
  @max_ids 100
  @low_remaining_threshold 100

  @pr_fields """
  id
  number
  state
  isDraft
  baseRefName
  headRefName
  headRefOid
  title
  url
  author { login ... on User { databaseId } }
  mergedBy { login ... on User { databaseId } }
  createdAt
  updatedAt
  closedAt
  mergedAt
  mergeCommit { oid }
  labels(first: 50) { nodes { name } }
  """

  @query """
  query($ids: [ID!]!) {
    rateLimit { cost remaining resetAt }
    nodes(ids: $ids) {
      __typename
      ... on PullRequest {
        #{@pr_fields}
      }
    }
  }
  """

  @search_query """
  query($q: String!, $first: Int!, $after: String) {
    rateLimit { cost remaining resetAt }
    search(query: $q, type: ISSUE, first: $first, after: $after) {
      issueCount
      pageInfo { endCursor hasNextPage }
      nodes {
        __typename
        ... on PullRequest {
          #{@pr_fields}
        }
      }
    }
  }
  """

  @type result :: %{String.t() => PullRequest.t() | :not_found}
  @type opt ::
          {:token, String.t()}
          | {:plug, term()}
          | {:rate_limit_table, atom()}

  @doc """
  Fetches pull request summaries for the given GraphQL node IDs.

  Returns a map keyed by input `node_id`. Missing PRs (deleted or
  transferred) are surfaced as `:not_found` rather than failing the batch.
  """
  @spec fetch_prs([String.t()], [opt]) ::
          {:ok, result}
          | {:error, Error.t() | :too_many_ids | {:graphql_errors, list} | term}
  def fetch_prs([], _opts), do: {:ok, %{}}

  def fetch_prs(node_ids, _opts) when length(node_ids) > @max_ids do
    {:error, :too_many_ids}
  end

  def fetch_prs(node_ids, opts) when is_list(node_ids) do
    token = Keyword.get_lazy(opts, :token, &Tracker.GitHub.installation_token!/0)
    plug = Keyword.get(opts, :plug)
    table = Keyword.get(opts, :rate_limit_table, RateLimitCache)

    req_opts =
      [
        method: :post,
        url: @endpoint,
        headers: [
          {"authorization", "bearer #{token}"},
          {"accept", "application/vnd.github+json"},
          {"user-agent", "Tracker"}
        ],
        json: %{query: @query, variables: %{ids: node_ids}},
        decode_body: true,
        retry: false
      ]
      |> maybe_add_plug(plug)

    case Req.request(Req.new(), req_opts) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        handle_body(body, node_ids, table)

      {:ok, %Req.Response{status: status}} when status in [403, 429] ->
        {:error, rate_limit_error(status)}

      {:ok, %Req.Response{status: status, body: body}} when status >= 500 ->
        {:error,
         Error.new(
           code: status,
           message: "GitHub GraphQL server error (#{status})",
           source: body,
           step: {__MODULE__, :fetch_prs}
         )}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error,
         Error.new(
           code: status,
           message: "Unexpected GitHub GraphQL status (#{status})",
           source: body,
           step: {__MODULE__, :fetch_prs}
         )}

      {:error, reason} ->
        {:error,
         Error.new(
           message: "Error during GraphQL request",
           source: reason,
           step: {__MODULE__, :fetch_prs}
         )}
    end
  end

  @type page :: %{
          pulls: [PullRequest.t()],
          next_cursor: String.t() | nil,
          issue_count: non_neg_integer()
        }

  @doc """
  Searches `repo` for pull requests updated at or after `since`, sorted
  ascending by `updatedAt`.

  Anchoring on a stable lower bound (vs. a mutable upper bound) avoids the
  cursor-drift skips inherent to descending walks of `pullRequests` ordered
  by a mutable field.

  Returns a single page of up to `:first` results plus the cursor for the
  next page and the total `issueCount` from GitHub. Callers paginate by
  re-invoking with `cursor: result.next_cursor` until `next_cursor` is `nil`.

  Note: the GitHub Search API caps results at 1000 regardless of pagination.
  Callers handling potentially large result sets should advance `since` and
  re-query when `issue_count > 1000`.
  """
  @spec search_repository_prs(String.t(), DateTime.t(), keyword) ::
          {:ok, page} | {:error, term}
  def search_repository_prs(repo, %DateTime{} = since, opts \\ []) when is_binary(repo) do
    token = Keyword.get_lazy(opts, :token, &Tracker.GitHub.installation_token!/0)
    plug = Keyword.get(opts, :plug)
    table = Keyword.get(opts, :rate_limit_table, RateLimitCache)
    first = Keyword.get(opts, :first, 100)
    cursor = Keyword.get(opts, :cursor)

    variables = %{
      "q" => build_search_query(repo, since),
      "first" => first,
      "after" => cursor
    }

    req_opts =
      [
        method: :post,
        url: @endpoint,
        headers: [
          {"authorization", "bearer #{token}"},
          {"accept", "application/vnd.github+json"},
          {"user-agent", "Tracker"}
        ],
        json: %{query: @search_query, variables: variables},
        decode_body: true,
        retry: false
      ]
      |> maybe_add_plug(plug)

    case Req.request(Req.new(), req_opts) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        handle_search_body(body, table)

      {:ok, %Req.Response{status: status}} when status in [403, 429] ->
        {:error, rate_limit_error(status)}

      {:ok, %Req.Response{status: status, body: body}} when status >= 500 ->
        {:error,
         Error.new(
           code: status,
           message: "GitHub GraphQL server error (#{status})",
           source: body,
           step: {__MODULE__, :search_repository_prs}
         )}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error,
         Error.new(
           code: status,
           message: "Unexpected GitHub GraphQL status (#{status})",
           source: body,
           step: {__MODULE__, :search_repository_prs}
         )}

      {:error, reason} ->
        {:error,
         Error.new(
           message: "Error during GraphQL request",
           source: reason,
           step: {__MODULE__, :search_repository_prs}
         )}
    end
  end

  defp build_search_query(repo, %DateTime{} = since) do
    iso = since |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    "repo:#{repo} is:pr updated:>=#{iso} sort:updated-asc"
  end

  defp handle_search_body(%{"errors" => errors} = body, _table)
       when is_list(errors) and not is_map_key(body, "data") do
    handle_errors_only(errors)
  end

  defp handle_search_body(%{"data" => nil, "errors" => errors}, _table)
       when is_list(errors) do
    handle_errors_only(errors)
  end

  defp handle_search_body(
         %{"data" => %{"search" => search_conn} = data} = body,
         table
       ) do
    if errors = Map.get(body, "errors") do
      Logger.warning("GitHub GraphQL returned partial errors: #{inspect(errors)}")
    end

    rate_limit = Map.get(data, "rateLimit")
    maybe_log_cost(rate_limit)
    maybe_track_rate_limit(rate_limit, table)

    nodes = Map.get(search_conn, "nodes", [])
    page_info = Map.get(search_conn, "pageInfo", %{})
    issue_count = Map.get(search_conn, "issueCount", 0)

    pulls =
      nodes
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&(&1["__typename"] == "PullRequest"))
      |> Enum.map(&decode_pr(&1["id"], &1))

    next_cursor =
      case page_info do
        %{"hasNextPage" => true, "endCursor" => c} when is_binary(c) -> c
        _ -> nil
      end

    {:ok, %{pulls: pulls, next_cursor: next_cursor, issue_count: issue_count}}
  end

  defp handle_search_body(body, _table) do
    {:error,
     Error.new(
       message: "Malformed GitHub GraphQL response",
       source: body,
       step: {__MODULE__, :search_repository_prs}
     )}
  end

  defp maybe_log_cost(%{"cost" => cost}) when is_integer(cost) do
    Logger.debug("GitHub GraphQL query cost: #{cost}")
  end

  defp maybe_log_cost(_), do: :ok

  defp handle_body(%{"errors" => errors} = body, _node_ids, _table)
       when is_list(errors) and not is_map_key(body, "data") do
    handle_errors_only(errors)
  end

  defp handle_body(%{"data" => nil, "errors" => errors}, _node_ids, _table)
       when is_list(errors) do
    handle_errors_only(errors)
  end

  defp handle_body(%{"data" => %{"nodes" => nodes} = data} = body, node_ids, table) do
    if errors = Map.get(body, "errors") do
      Logger.warning("GitHub GraphQL returned partial errors: #{inspect(errors)}")
    end

    maybe_track_rate_limit(Map.get(data, "rateLimit"), table)

    result =
      node_ids
      |> Enum.zip(nodes)
      |> Map.new(fn {id, node} -> {id, decode_node(id, node)} end)

    {:ok, result}
  end

  defp handle_body(body, _node_ids, _table) do
    {:error,
     Error.new(
       message: "Malformed GitHub GraphQL response",
       source: body,
       step: {__MODULE__, :fetch_prs}
     )}
  end

  defp handle_errors_only(errors) do
    if rate_limited_error?(errors) do
      {:error, rate_limit_error(nil)}
    else
      {:error, {:graphql_errors, errors}}
    end
  end

  defp decode_node(_id, nil), do: :not_found

  defp decode_node(id, %{"__typename" => "PullRequest"} = node), do: decode_pr(id, node)
  defp decode_node(_id, _other), do: :not_found

  defp decode_pr(node_id, node) do
    %PullRequest{
      node_id: node_id,
      number: node["number"],
      state: decode_state(node["state"], node["isDraft"]),
      base_ref: node["baseRefName"],
      head_ref: node["headRefName"],
      head_sha: node["headRefOid"],
      title: node["title"],
      url: node["url"],
      author: get_in(node, ["author", "login"]),
      author_github_id: get_in(node, ["author", "databaseId"]),
      merged_by_github_id: get_in(node, ["mergedBy", "databaseId"]),
      created_at: parse_datetime(node["createdAt"]),
      updated_at: parse_datetime(node["updatedAt"]),
      closed_at: parse_datetime(node["closedAt"]),
      merged_at: parse_datetime(node["mergedAt"]),
      merge_commit_sha: get_in(node, ["mergeCommit", "oid"]),
      labels: decode_labels(node["labels"])
    }
  end

  defp decode_state("OPEN", true), do: :draft
  defp decode_state("OPEN", _), do: :open
  defp decode_state("CLOSED", _), do: :closed
  defp decode_state("MERGED", _), do: :merged

  defp decode_labels(%{"nodes" => nodes}) when is_list(nodes) do
    Enum.map(nodes, & &1["name"])
  end

  defp decode_labels(_), do: []

  defp parse_datetime(nil), do: nil

  defp parse_datetime(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp maybe_track_rate_limit(%{"remaining" => remaining, "resetAt" => reset_at}, table)
       when is_integer(remaining) and remaining < @low_remaining_threshold do
    case parse_datetime(reset_at) do
      %DateTime{} = dt ->
        RateLimitCache.set_reset(:graphql, DateTime.to_unix(dt), table)

      _ ->
        :ok
    end
  end

  defp maybe_track_rate_limit(_, _), do: :ok

  defp rate_limited_error?(errors) do
    Enum.any?(errors, fn
      %{"type" => "RATE_LIMITED"} -> true
      _ -> false
    end)
  end

  defp rate_limit_error(status) do
    Error.new(
      code: status,
      message: "GitHub GraphQL rate limited",
      reason: :rate_limited,
      step: {__MODULE__, :fetch_prs}
    )
  end

  defp maybe_add_plug(opts, nil), do: opts
  defp maybe_add_plug(opts, plug), do: Keyword.put(opts, :plug, plug)
end

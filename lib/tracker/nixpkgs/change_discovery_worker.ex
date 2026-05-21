defmodule Tracker.Nixpkgs.ChangeDiscoveryWorker do
  @moduledoc """
  Periodically discovers new or recently-updated nixpkgs PRs and upserts
  them into the Change resource.

  Covers the full PR lifecycle (draft/open/closed/merged) — not just
  merges. Artifact processing is driven separately by the refresh worker
  based on state transitions.

  Uses GitHub's GraphQL `search` API anchored on a stable lower bound
  (`updated:>=since sort:updated-asc`) and drains every page. Anchoring
  on a lower bound rather than walking `pullRequests` ordered by
  `UPDATED_AT DESC` avoids cursor-drift skips at page boundaries when
  PRs are re-bumped or created mid-pagination.
  """
  use Oban.Worker, queue: :changes, max_attempts: 5

  require Logger

  alias Tracker.GitHub.GraphQL
  alias Tracker.GitHub.GraphQL.PullRequest
  alias Tracker.Nixpkgs.Change
  alias Tracker.Nixpkgs.ChangeArtifactRefreshWorker
  alias Tracker.Nixpkgs.ChangeBranch
  alias Tracker.Nixpkgs.ChangeTransitions

  @repo "NixOS/nixpkgs"
  @checkpoint_floor_days 90
  @checkpoint_overlap_seconds 60
  @search_result_cap 1000
  @max_cycles 100

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: run([]) |> to_oban_result()

  @doc false
  def to_oban_result({:error, reason}), do: {:cancel, reason}
  def to_oban_result(other), do: other

  @doc """
  Runs discovery, paginating through new/updated PRs since the current checkpoint.

  Options:
    * `:rate_limit_table` — ETS table for the rate-limit cache (tests).
    * `:fetcher` — `(since, cursor) -> {:ok, page} | {:error, term}` (tests).
    * `:snoozer` — `() -> non_neg_integer()` (tests).
  """
  def run(opts \\ []) do
    since = checkpoint()
    Logger.info(msg: "discovery started", since: since)
    started_at = System.monotonic_time()
    table = Keyword.get(opts, :rate_limit_table, Tracker.GitHub.RateLimitCache)

    {return_value, summary} =
      case Tracker.GitHub.RateLimitCache.check(:graphql, table) do
        {:limited, seconds} ->
          {:ok, %{outcome: :rate_limited, skip_seconds: seconds}}

        :ok ->
          fetcher =
            Keyword.get_lazy(opts, :fetcher, fn ->
              token = Tracker.GitHub.installation_token!()
              page_fetcher(@repo, token)
            end)

          discover_with(fetcher, since, opts)
      end

    Logger.info(
      [msg: "discovery finished"] ++
        Enum.to_list(summary) ++ [duration_ms: duration_ms(started_at)]
    )

    return_value
  end

  defp discover_with(fetcher, since, opts) do
    case discover_pages(fetcher, since) do
      {:ok, count} ->
        {:ok, %{outcome: :ok, upserted: count}}

      {:error, %GitHub.Error{reason: :rate_limited}} ->
        snooze_seconds = snooze_seconds(opts)

        Logger.warning(
          msg: "GitHub GraphQL rate limited, snoozing discovery worker",
          seconds: snooze_seconds
        )

        {{:snooze, snooze_seconds}, %{outcome: :snoozed, snooze_seconds: snooze_seconds}}

      {:error, reason} ->
        Logger.error(msg: "Failed to discover pulls", reason: inspect(reason))
        {{:error, reason}, %{outcome: :error, reason: inspect(reason)}}
    end
  end

  defp snooze_seconds(opts) do
    case Keyword.fetch(opts, :snoozer) do
      {:ok, fun} ->
        fun.()

      :error ->
        token = Tracker.GitHub.installation_token!()
        Tracker.GitHub.seconds_until_reset(token, :graphql)
    end
  end

  defp duration_ms(started_at) do
    System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)
  end

  @doc """
  Drains every PR updated at or after `since`, paginating through the
  fetcher's results until exhausted.

  Re-queries with an advanced lower bound when the GitHub Search API's
  #{@search_result_cap}-result cap is hit (`issue_count > #{@search_result_cap}`),
  so no PRs are dropped during high-volume catch-up windows.

  The `fetcher` is `(since :: DateTime.t(), cursor :: String.t() | nil) ->
    {:ok, page} | {:error, term}` where `page` is
  `%{pulls: [PullRequest.t()], next_cursor: String.t() | nil,
     issue_count: non_neg_integer()}`.

  Returns `{:ok, upserted_count}` or `{:error, reason}`.
  """
  def discover_pages(fetcher, %DateTime{} = since) do
    drain(fetcher, since, 0, 1)
  end

  defp drain(_fetcher, _since, total, cycle) when cycle > @max_cycles do
    Logger.warning(msg: "discovery hit max cycles", cycle: cycle, upserted: total)
    {:ok, total}
  end

  defp drain(fetcher, since, total, cycle) do
    case drain_query(fetcher, since, nil, 0, nil) do
      {:ok, {0, _last, _capped?}} ->
        {:ok, total}

      {:ok, {count, last_updated_at, true}} when not is_nil(last_updated_at) ->
        Logger.info(
          msg: "discovery hit search result cap, advancing since",
          cycle: cycle,
          upserted_so_far: total + count,
          new_since: last_updated_at
        )

        drain(fetcher, last_updated_at, total + count, cycle + 1)

      {:ok, {count, _last, _capped?}} ->
        {:ok, total + count}

      {:error, _reason} = error ->
        error
    end
  end

  defp drain_query(fetcher, since, cursor, count, last_updated_at) do
    case fetcher.(since, cursor) do
      {:ok, %{pulls: pulls, next_cursor: next_cursor, issue_count: issue_count}} ->
        {:ok, _} = upsert_pulls(pulls)
        new_count = count + length(pulls)
        new_last = max_updated_at(last_updated_at, pulls)

        Logger.info(
          msg: "discovery page processed",
          cursor: cursor || "<initial>",
          fetched: length(pulls),
          issue_count: issue_count
        )

        if is_nil(next_cursor) do
          {:ok, {new_count, new_last, issue_count > @search_result_cap}}
        else
          drain_query(fetcher, since, next_cursor, new_count, new_last)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp max_updated_at(prev, pulls) do
    Enum.reduce(pulls, prev, fn
      %PullRequest{updated_at: %DateTime{} = u}, nil ->
        u

      %PullRequest{updated_at: %DateTime{} = u}, acc ->
        if DateTime.after?(u, acc), do: u, else: acc

      _, acc ->
        acc
    end)
  end

  @doc """
  Upserts a list of `Tracker.GitHub.GraphQL.PullRequest` structs into the
  Change resource. Seeds `ChangeBranch` rows for any record landing in
  `:merged` so historical/just-discovered merges record their merge target
  without waiting for the periodic ancestor check.

  Returns `{:ok, count}` with the number of rows upserted.
  """
  def upsert_pulls(pulls) when is_list(pulls) do
    case pulls do
      [] ->
        {:ok, 0}

      _ ->
        records = Enum.map(pulls, &parse_pr_payload/1)
        prior_by_number = prior_state_lookup(records)
        number_to_id = Change.bulk_upsert_all(records)
        emit_changes(records, prior_by_number, number_to_id)
        {:ok, length(records)}
    end
  end

  defp prior_state_lookup(records) do
    records
    |> Enum.map(& &1.number)
    |> Change.preexisting_for_diff!()
    |> Map.new(&{&1.number, &1})
  end

  defp emit_changes(records, prior_by_number, number_to_id) do
    Enum.each(records, fn record ->
      case Map.fetch(prior_by_number, record.number) do
        :error ->
          handle_new_record(record, number_to_id)

        {:ok, prior} ->
          handle_existing_record(record, prior, number_to_id)
      end
    end)
  end

  defp handle_new_record(record, number_to_id) do
    if record.state in [:open, :draft] do
      %{"number" => record.number, "reason" => "head_sha_changed"}
      |> ChangeArtifactRefreshWorker.new()
      |> Oban.insert!()
    end

    if record.state == :merged do
      seed_base_ref(record, number_to_id)
    end
  end

  defp handle_existing_record(record, prior, number_to_id) do
    pr_like = struct!(PullRequest, pr_like_from_record(record))

    case ChangeTransitions.detect(prior, pr_like) do
      [] ->
        :ok

      transitions ->
        change = build_change_for_emit(record, prior, number_to_id)
        Enum.each(transitions, &ChangeTransitions.emit(change, &1))
    end
  end

  defp pr_like_from_record(record) do
    %{
      node_id: record.node_id,
      number: record.number,
      title: record.title,
      state: record.state,
      head_sha: record.head_sha,
      updated_at: record.gh_updated_at,
      merged_at: record.merged_at,
      closed_at: record.closed_at,
      merge_commit_sha: record.merge_commit_sha
    }
  end

  defp build_change_for_emit(record, prior, number_to_id) do
    %Change{
      id: prior.id || Map.fetch!(number_to_id, record.number),
      number: record.number,
      node_id: record.node_id,
      base_ref: record.base_ref,
      state: record.state
    }
  end

  defp seed_base_ref(record, number_to_id) do
    case Map.fetch(number_to_id, record.number) do
      {:ok, change_id} -> ChangeBranch.seed_for_base_ref(change_id, record.base_ref)
      :error -> :ok
    end
  end

  @doc """
  Maps a `Tracker.GitHub.GraphQL.PullRequest` to a Change attribute map
  suitable for `Tracker.Nixpkgs.Change.bulk_upsert_all/1`.
  """
  def parse_pr_payload(%PullRequest{} = pr) do
    %{
      number: pr.number,
      node_id: pr.node_id,
      title: pr.title,
      state: pr.state,
      author: pr.author,
      author_github_id: pr.author_github_id,
      merged_by_github_id: pr.merged_by_github_id,
      url: pr.url,
      base_ref: pr.base_ref,
      head_ref: pr.head_ref,
      head_sha: pr.head_sha,
      labels: pr.labels || [],
      gh_created_at: pr.created_at,
      gh_updated_at: pr.updated_at,
      closed_at: pr.closed_at,
      merged_at: pr.merged_at,
      merge_commit_sha: (pr.state == :merged && pr.merge_commit_sha) || nil
    }
  end

  @doc """
  Backfills historical PRs by anchoring on the #{@checkpoint_floor_days}-day
  floor and draining via the same `search`-based path as scheduled discovery.

  Stops when it reaches PRs older than #{@checkpoint_floor_days} days
  (artifact expiry window).
  """
  def backfill do
    token = Tracker.GitHub.installation_token!()
    cutoff = DateTime.utc_now() |> DateTime.add(-@checkpoint_floor_days, :day)
    Logger.info(msg: "discovery backfill started", since: cutoff)
    started_at = System.monotonic_time()

    {return_value, summary} =
      case discover_pages(page_fetcher(@repo, token), cutoff) do
        {:ok, count} ->
          {{:ok, count}, %{outcome: :ok, upserted: count}}

        {:error, %GitHub.Error{reason: :rate_limited}} ->
          seconds = Tracker.GitHub.seconds_until_reset(token, :graphql)
          {{:error, :rate_limited}, %{outcome: :rate_limited, reset_seconds: seconds}}

        {:error, reason} = error ->
          {error, %{outcome: :error, reason: inspect(reason)}}
      end

    Logger.info(
      [msg: "discovery backfill finished"] ++
        Enum.to_list(summary) ++ [duration_ms: duration_ms(started_at)]
    )

    return_value
  end

  defp page_fetcher(repo, token) do
    fn since, cursor ->
      GraphQL.search_repository_prs(repo, since, token: token, cursor: cursor, first: 100)
    end
  end

  @doc """
  Returns the lower bound for the next discovery walk: the most recent
  `gh_updated_at` we've upserted, minus a #{@checkpoint_overlap_seconds}-second
  overlap to absorb GitHub search index lag (a freshly opened PR may take
  seconds to surface in search results).

  Falls back to a #{@checkpoint_floor_days}-day floor when the DB is empty
  or when the recorded max would otherwise put us further back than the
  artifact expiry window.
  """
  def checkpoint do
    floor = DateTime.utc_now() |> DateTime.add(-@checkpoint_floor_days, :day)

    case Change.max_gh_updated_at() do
      {:ok, %DateTime{} = dt} ->
        anchored = DateTime.add(dt, -@checkpoint_overlap_seconds, :second)
        if DateTime.before?(anchored, floor), do: floor, else: anchored

      _ ->
        floor
    end
  end
end

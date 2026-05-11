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

  @repo "NixOS/nixpkgs"
  @checkpoint_floor_days 90
  @checkpoint_overlap_seconds 60
  @search_result_cap 1000
  @max_cycles 100

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Tracker.GitHub.RateLimitCache.check(:graphql) do
      {:limited, seconds} ->
        Logger.info("Rate limited for #{seconds}s, skipping discovery")
        :ok

      :ok ->
        token = Tracker.GitHub.installation_token!()
        fetcher = page_fetcher(@repo, token)

        case discover_pages(fetcher, checkpoint()) do
          {:ok, _count} ->
            :ok

          {:error, %GitHub.Error{reason: :rate_limited}} ->
            snooze_seconds = Tracker.GitHub.seconds_until_reset(token, :graphql)

            Logger.warning(
              "GitHub GraphQL rate limited, snoozing discovery worker #{snooze_seconds}s"
            )

            {:snooze, snooze_seconds}

          {:error, reason} ->
            Logger.error("Failed to discover pulls: #{inspect(reason)}")
            {:error, reason}
        end
    end
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
        preexisting = preexisting_numbers(records)
        number_to_id = Change.bulk_upsert_all(records)
        enqueue_artifact_refresh_for_new_open_drafts(records, preexisting)
        seed_base_ref_for_merged(records, number_to_id)
        {:ok, length(records)}
    end
  end

  defp preexisting_numbers(records) do
    records
    |> Enum.map(& &1.number)
    |> Change.existing_numbers!()
    |> MapSet.new(& &1.number)
  end

  defp enqueue_artifact_refresh_for_new_open_drafts(records, preexisting) do
    Enum.each(records, fn record ->
      if record.state in [:open, :draft] and record.number not in preexisting do
        %{"number" => record.number, "reason" => "head_sha_changed"}
        |> ChangeArtifactRefreshWorker.new()
        |> Oban.insert!()
      end
    end)
  end

  defp seed_base_ref_for_merged(records, number_to_id) do
    Enum.each(records, fn record ->
      with :merged <- record.state,
           {:ok, change_id} <- Map.fetch(number_to_id, record.number) do
        ChangeBranch.seed_for_base_ref(change_id, record.base_ref)
      end
    end)
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

    case discover_pages(page_fetcher(@repo, token), cutoff) do
      {:ok, count} ->
        Logger.info("Backfill complete: upserted #{count} PRs")
        {:ok, count}

      {:error, %GitHub.Error{reason: :rate_limited}} ->
        seconds = Tracker.GitHub.seconds_until_reset(token, :graphql)
        minutes = div(seconds, 60)
        Logger.warning("Rate limited during backfill. Reset in #{minutes}m.")
        {:error, :rate_limited}

      {:error, reason} = error ->
        Logger.error("Backfill failed: #{inspect(reason)}")
        error
    end
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

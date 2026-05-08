defmodule Tracker.Nixpkgs.ChangeDiscoveryWorker do
  @moduledoc """
  Periodically discovers new or recently-updated nixpkgs PRs and upserts
  them into the Change resource.

  Covers the full PR lifecycle (draft/open/closed/merged) — not just
  merges. Artifact processing is driven separately by the refresh worker
  based on state transitions.

  Uses GitHub's GraphQL API so the listing response carries fields the
  REST list endpoint omits — notably `mergedBy` (populates
  `changes.merged_by_github_id`) and the real `mergeCommit.oid`.
  """
  use Oban.Worker, queue: :changes, max_attempts: 5

  require Logger

  alias Tracker.GitHub.GraphQL
  alias Tracker.GitHub.GraphQL.PullRequest
  alias Tracker.Nixpkgs.Change
  alias Tracker.Nixpkgs.ChangeArtifactRefreshWorker
  alias Tracker.Nixpkgs.ChangeBranch

  @repo "NixOS/nixpkgs"
  @watermark_floor_days 90
  @max_pages 10

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Tracker.GitHub.RateLimitCache.check(:graphql) do
      {:limited, seconds} ->
        Logger.info("Rate limited for #{seconds}s, skipping discovery")
        :ok

      :ok ->
        [owner, repo] = String.split(@repo, "/")
        token = Tracker.GitHub.installation_token!()
        fetcher = page_fetcher(owner, repo, token)

        case discover_pages(fetcher, watermark()) do
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
  Pages through the fetcher's results, upserting every PR on every fetched
  page. Stops when:

  - The fetcher returns no pulls
  - The fetcher returns `next_cursor: nil`
  - The last PR on a page has `updated_at < watermark` (all older PRs on
    later pages have already been seen or are out of our lookback window)
  - The maximum page limit (#{@max_pages}) is reached

  The `fetcher` is `(cursor :: String.t() | nil) -> {:ok, page} | {:error, term}`
  where `page` is `%{pulls: [PullRequest.t()], next_cursor: String.t() | nil}`.

  Returns `{:ok, upserted_count}` or `{:error, reason}`.
  """
  def discover_pages(fetcher, %DateTime{} = watermark) do
    discover_page(fetcher, watermark, nil, 1, 0)
  end

  defp discover_page(_fetcher, _watermark, _cursor, page, total) when page > @max_pages do
    Logger.warning(msg: "discovery hit max page limit", page: page, upserted: total)
    {:ok, total}
  end

  defp discover_page(fetcher, watermark, cursor, page, total) do
    case fetcher.(cursor) do
      {:ok, %{pulls: [], next_cursor: _}} ->
        Logger.info(msg: "discovery page empty, stopping", page: page, upserted: total)
        {:ok, total}

      {:ok, %{pulls: pulls, next_cursor: next_cursor}} ->
        {:ok, count} = upsert_pulls(pulls)

        Logger.info(
          msg: "discovery page processed",
          page: page,
          fetched: length(pulls),
          upserted: count
        )

        cond do
          is_nil(next_cursor) ->
            {:ok, total + count}

          last_older_than_watermark?(pulls, watermark) ->
            Logger.info(
              msg: "discovery reached watermark, stopping",
              page: page,
              upserted: total + count
            )

            {:ok, total + count}

          true ->
            discover_page(fetcher, watermark, next_cursor, page + 1, total + count)
        end

      {:error, _reason} = error ->
        error
    end
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
  Backfills historical PRs by paging backwards through the GitHub API
  using the same full-lifecycle upsert path as scheduled discovery.

  Stops when it reaches PRs older than #{@watermark_floor_days} days
  (artifact expiry window).
  """
  def backfill do
    [owner, repo] = String.split(@repo, "/")
    token = Tracker.GitHub.installation_token!()
    cutoff = DateTime.utc_now() |> DateTime.add(-@watermark_floor_days, :day)

    case discover_pages(page_fetcher(owner, repo, token), cutoff) do
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

  defp page_fetcher(owner, repo, token) do
    fn cursor ->
      GraphQL.list_repository_prs(owner, repo, token: token, cursor: cursor, first: 100)
    end
  end

  @doc false
  def watermark do
    floor = DateTime.utc_now() |> DateTime.add(-@watermark_floor_days, :day)

    case Change.max_gh_updated_at() do
      {:ok, %DateTime{} = dt} ->
        if DateTime.before?(dt, floor), do: floor, else: dt

      _ ->
        floor
    end
  end

  defp last_older_than_watermark?(pulls, watermark) do
    case List.last(pulls) do
      %PullRequest{updated_at: %DateTime{} = updated_at} ->
        DateTime.before?(updated_at, watermark)

      _ ->
        false
    end
  end
end

defmodule Tracker.Nixpkgs.ChangeDiscoveryWorker do
  @moduledoc """
  Periodically discovers new or recently-updated nixpkgs PRs and upserts
  them into the Change resource.

  Covers the full PR lifecycle (draft/open/closed/merged) — not just
  merges. Artifact processing is driven separately by the refresh worker
  based on state transitions.
  """
  use Oban.Worker, queue: :changes, max_attempts: 5

  require Logger

  alias Tracker.Nixpkgs.Change
  alias Tracker.Nixpkgs.ChangeArtifactRefreshWorker

  @repo "NixOS/nixpkgs"
  @watermark_floor_days 90
  @max_pages 10

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Tracker.GitHub.RateLimitCache.check(:rest) do
      {:limited, seconds} ->
        Logger.info("Rate limited for #{seconds}s, skipping discovery")
        :ok

      :ok ->
        token = Tracker.GitHub.installation_token!()
        [owner, repo] = String.split(@repo, "/")

        fetcher = fn page ->
          GitHub.Pulls.list(owner, repo,
            state: "all",
            sort: "updated",
            direction: "desc",
            per_page: 100,
            page: page,
            auth: token
          )
        end

        case discover_pages(fetcher, watermark()) do
          {:ok, _count} ->
            :ok

          {:error, %GitHub.Error{reason: :rate_limited}} ->
            snooze_seconds = Tracker.GitHub.seconds_until_reset(token, :rest)

            Logger.warning(
              "GitHub API rate limited, snoozing discovery worker #{snooze_seconds}s"
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

  - An empty page is returned
  - The last PR on a page has `updated_at < watermark` (all older PRs on
    later pages have already been seen or are out of our lookback window)
  - The maximum page limit (#{@max_pages}) is reached

  Returns `{:ok, upserted_count}` or `{:error, reason}`.
  """
  def discover_pages(fetcher, %DateTime{} = watermark) do
    discover_page(fetcher, watermark, 1, 0)
  end

  defp discover_page(_fetcher, _watermark, page, total) when page > @max_pages do
    Logger.warning(msg: "discovery hit max page limit", page: page, upserted: total)
    {:ok, total}
  end

  defp discover_page(fetcher, watermark, page, total) do
    case fetcher.(page) do
      {:ok, []} ->
        Logger.info(msg: "discovery page empty, stopping", page: page, upserted: total)
        {:ok, total}

      {:ok, pulls} ->
        {:ok, count} = upsert_pulls(pulls)

        Logger.info(
          msg: "discovery page processed",
          page: page,
          fetched: length(pulls),
          upserted: count
        )

        if last_older_than_watermark?(pulls, watermark) do
          Logger.info(
            msg: "discovery reached watermark, stopping",
            page: page,
            upserted: total + count
          )

          {:ok, total + count}
        else
          discover_page(fetcher, watermark, page + 1, total + count)
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Upserts a list of PR structs into the Change resource.

  Returns `{:ok, count}` with the number of rows upserted.
  """
  def upsert_pulls(pulls) when is_list(pulls) do
    case pulls do
      [] ->
        {:ok, 0}

      _ ->
        records = Enum.map(pulls, &parse_pr_payload/1)
        preexisting = preexisting_numbers(records)
        _ = Change.bulk_upsert_all(records)
        enqueue_artifact_refresh_for_new_open_drafts(records, preexisting)
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

  @doc """
  Parses a `GitHub.PullRequest` struct into a map of Change attributes
  suitable for `Tracker.Nixpkgs.Change.bulk_upsert_all/1`.
  """
  def parse_pr_payload(pr) do
    merged_by = Map.get(pr, :merged_by)

    %{
      number: pr.number,
      node_id: pr.node_id,
      title: pr.title,
      state: parse_state(pr),
      author: pr.user && pr.user.login,
      author_github_id: pr.user && pr.user.id,
      merged_by_github_id: merged_by && merged_by.id,
      url: pr.html_url,
      base_ref: pr.base && pr.base.ref,
      head_ref: pr.head && pr.head.ref,
      head_sha: pr.head && pr.head.sha,
      labels: Enum.map(pr.labels || [], & &1.name),
      gh_created_at: parse_datetime(pr.created_at),
      gh_updated_at: parse_datetime(pr.updated_at),
      closed_at: parse_datetime(pr.closed_at),
      merged_at: parse_datetime(pr.merged_at),
      merge_commit_sha: pr.merge_commit_sha
    }
  end

  @doc """
  Backfills historical PRs by paging backwards through the GitHub API
  using the same full-lifecycle upsert path as scheduled discovery.

  Stops when it reaches PRs older than #{@watermark_floor_days} days
  (artifact expiry window).
  """
  def backfill do
    token = Tracker.GitHub.installation_token!()
    cutoff = DateTime.utc_now() |> DateTime.add(-@watermark_floor_days, :day)
    [owner, repo] = String.split(@repo, "/")

    fetcher = fn page ->
      GitHub.Pulls.list(owner, repo,
        state: "all",
        sort: "updated",
        direction: "desc",
        per_page: 100,
        page: page,
        auth: token
      )
    end

    case discover_pages(fetcher, cutoff) do
      {:ok, count} ->
        Logger.info("Backfill complete: upserted #{count} PRs")
        {:ok, count}

      {:error, %GitHub.Error{reason: :rate_limited}} ->
        seconds = Tracker.GitHub.seconds_until_reset(token, :rest)
        minutes = div(seconds, 60)
        Logger.warning("Rate limited during backfill. Reset in #{minutes}m.")
        {:error, :rate_limited}

      {:error, reason} = error ->
        Logger.error("Backfill failed: #{inspect(reason)}")
        error
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
      %{updated_at: %DateTime{} = updated_at} -> DateTime.before?(updated_at, watermark)
      _ -> false
    end
  end

  defp parse_state(%{merged_at: %DateTime{}}), do: :merged
  defp parse_state(%{state: "closed"}), do: :closed
  defp parse_state(%{draft: true}), do: :draft
  defp parse_state(_), do: :open

  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = dt), do: dt

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
end

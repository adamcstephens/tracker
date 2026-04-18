defmodule Tracker.Nixpkgs.ChangePollWorker do
  @moduledoc """
  Periodically polls GitHub for newly merged nixpkgs PRs and enqueues
  individual processing jobs for each.
  """
  use Oban.Worker, queue: :changes, max_attempts: 5

  require Logger

  @repo "NixOS/nixpkgs"
  @backfill_cutoff_days 90
  @max_pages 10

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Tracker.GitHub.RateLimitCache.check() do
      {:limited, seconds} ->
        Logger.info("Rate limited for #{seconds}s, skipping poll")
        :ok

      :ok ->
        token = Tracker.GitHub.installation_token!()
        [owner, repo] = String.split(@repo, "/")

        fetcher = fn page ->
          GitHub.Pulls.list(owner, repo,
            state: "closed",
            sort: "updated",
            direction: "desc",
            per_page: 100,
            page: page,
            auth: token
          )
        end

        case poll_pages(fetcher) do
          :ok ->
            :ok

          {:error, %GitHub.Error{reason: :rate_limited}} ->
            snooze_seconds = Tracker.GitHub.seconds_until_reset(token)
            Logger.warning("GitHub API rate limited, snoozing poll worker #{snooze_seconds}s")
            {:snooze, snooze_seconds}

          {:error, reason} ->
            Logger.error("Failed to fetch pulls: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  @doc """
  Polls GitHub for merged PRs, paging through results until all PRs on a page
  are already known (or the page is empty). Accepts a fetcher function that
  takes a page number and returns `{:ok, pulls}` or `{:error, reason}`.

  Stops paging when:
  - An empty page is returned
  - No new merged PRs are found on a page (all already tracked)
  - The maximum page limit (#{@max_pages}) is reached
  """
  def poll_pages(fetcher), do: poll_page(fetcher, 1)

  defp poll_page(_fetcher, page) when page > @max_pages, do: :ok

  defp poll_page(fetcher, page) do
    case fetcher.(page) do
      {:ok, []} ->
        Logger.info(msg: "poll page returned empty, stopping", page: page)
        :ok

      {:ok, pulls} ->
        {:ok, count} = process_pull_requests(pulls)

        Logger.info(
          msg: "poll page processed",
          page: page,
          fetched: length(pulls),
          new: count
        )

        if count > 0 do
          poll_page(fetcher, page + 1)
        else
          :ok
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Processes a list of pull request payloads from the GitHub API.

  Filters to merged PRs, skips those already tracked, and enqueues
  a ChangeProcessWorker job for each new one.

  Returns `{:ok, count}` with the number of jobs enqueued.
  """
  def process_pull_requests(pulls) do
    merged = Enum.filter(pulls, & &1.merged_at)
    merged_numbers = Enum.map(merged, & &1.number)

    existing =
      case merged_numbers do
        [] -> MapSet.new()
        numbers -> existing_change_numbers(numbers)
      end

    new_numbers = Enum.reject(merged_numbers, &MapSet.member?(existing, &1))

    Enum.each(new_numbers, fn number ->
      %{"number" => number}
      |> Tracker.Nixpkgs.ChangeProcessWorker.new()
      |> Oban.insert!()
    end)

    {:ok, length(new_numbers)}
  end

  @doc """
  Backfills historical merged PRs by paging backwards through the GitHub API.

  Stops when it reaches PRs older than 90 days (artifact expiry window).
  Enqueues ChangeProcessWorker jobs for each new PR found.
  """
  def backfill do
    token = Tracker.GitHub.installation_token!()
    cutoff = DateTime.utc_now() |> DateTime.add(-@backfill_cutoff_days, :day)
    [owner, repo] = String.split(@repo, "/")

    backfill_page(owner, repo, token, cutoff, 1, 0)
  end

  defp backfill_page(owner, repo, token, cutoff, page_num, total_enqueued) do
    case GitHub.Pulls.list(owner, repo,
           state: "closed",
           sort: "updated",
           direction: "desc",
           per_page: 100,
           page: page_num,
           auth: token
         ) do
      {:ok, []} ->
        Logger.info("Backfill complete: no more PRs. Enqueued #{total_enqueued} jobs.")
        {:ok, total_enqueued}

      {:ok, pulls} ->
        recent = Enum.filter(pulls, &(&1.merged_at && !DateTime.before?(&1.merged_at, cutoff)))

        if recent == [] do
          Logger.info(
            "Backfill complete: all PRs on page #{page_num} are past #{@backfill_cutoff_days}-day cutoff. Enqueued #{total_enqueued} jobs."
          )

          {:ok, total_enqueued}
        else
          {:ok, count} = process_pull_requests(recent)

          Logger.info("Backfill page #{page_num}: enqueued #{count} jobs")
          backfill_page(owner, repo, token, cutoff, page_num + 1, total_enqueued + count)
        end

      {:error, %GitHub.Error{reason: :rate_limited}} ->
        seconds = Tracker.GitHub.seconds_until_reset(token)
        minutes = div(seconds, 60)

        Logger.warning(
          "Rate limited during backfill at page #{page_num}. Enqueued #{total_enqueued} jobs. Reset in #{minutes}m."
        )

        {:ok, total_enqueued}

      {:error, reason} ->
        Logger.error("Backfill failed at page #{page_num}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp existing_change_numbers(numbers) do
    numbers
    |> Tracker.Nixpkgs.Change.existing_numbers!()
    |> Enum.map(& &1.number)
    |> MapSet.new()
  end
end

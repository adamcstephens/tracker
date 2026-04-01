defmodule Tracker.Nixpkgs.ChangePollWorker do
  @moduledoc """
  Periodically polls GitHub for newly merged nixpkgs PRs and enqueues
  individual processing jobs for each.
  """
  use Oban.Worker, queue: :changes, max_attempts: 5

  require Logger

  @repo "NixOS/nixpkgs"
  @poll_interval_seconds 5 * 60
  @backfill_cutoff_days 90

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    fetch_merged_pulls() |> handle_fetch_result()
  end

  @doc false
  def handle_fetch_result({:ok, pulls}) do
    process_pull_requests(pulls)
    reschedule()
    :ok
  end

  def handle_fetch_result({:error, %GitHub.Error{reason: :rate_limited}}) do
    Logger.warning("GitHub API rate limited, snoozing poll worker")
    {:snooze, 60}
  end

  def handle_fetch_result({:error, reason}) do
    Logger.error("Failed to fetch pulls: #{inspect(reason)}")
    {:error, reason}
  end

  @doc """
  Processes a list of pull request payloads from the GitHub API.

  Filters to merged PRs, skips those already tracked, and enqueues
  a ChangeProcessWorker job for each new one.

  Returns `{:ok, count}` with the number of jobs enqueued.
  """
  def process_pull_requests(pulls) do
    merged_numbers =
      pulls
      |> Enum.filter(& &1.merged_at)
      |> Enum.map(& &1.number)

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
        merged = Enum.filter(pulls, & &1.merged_at)

        oldest = merged |> Enum.map(& &1.merged_at) |> Enum.min(DateTime, fn -> nil end)

        if oldest && DateTime.before?(oldest, cutoff) do
          # Filter to only PRs within the cutoff
          recent = Enum.filter(merged, &(!DateTime.before?(&1.merged_at, cutoff)))
          {:ok, count} = process_pull_requests(recent)

          Logger.info(
            "Backfill complete: reached #{@backfill_cutoff_days}-day cutoff. Enqueued #{total_enqueued + count} jobs."
          )

          {:ok, total_enqueued + count}
        else
          {:ok, count} = process_pull_requests(pulls)

          Logger.info("Backfill page #{page_num}: enqueued #{count} jobs")
          backfill_page(owner, repo, token, cutoff, page_num + 1, total_enqueued + count)
        end

      {:error, %GitHub.Error{reason: :rate_limited}} ->
        Logger.warning(
          "Rate limited during backfill at page #{page_num}, stopping. Enqueued #{total_enqueued} jobs so far."
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

  defp fetch_merged_pulls do
    [owner, repo] = String.split(@repo, "/")
    token = Tracker.GitHub.installation_token!()

    case GitHub.Pulls.list(owner, repo,
           state: "closed",
           sort: "updated",
           direction: "desc",
           per_page: 100,
           auth: token
         ) do
      {:ok, pulls} ->
        {:ok, pulls}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reschedule do
    %{} |> new(schedule_in: @poll_interval_seconds) |> Oban.insert!()
  end
end

defmodule Tracker.Nixpkgs.ChangeRefreshWorker do
  @moduledoc """
  Keeps non-terminal Changes in sync with GitHub using a single batched
  GraphQL lookup per run.

  Each invocation picks the stalest open/draft Changes (up to 100, the
  GraphQL batch cap), fetches their current state, applies state updates,
  and emits artifact-refresh transitions for consumers downstream.
  """
  use Oban.Worker, queue: :changes, max_attempts: 5

  require Logger

  @dormancy_threshold_days 30

  alias Tracker.GitHub.GraphQL.PullRequest
  alias Tracker.GitHub.RateLimitCache
  alias Tracker.Nixpkgs.Change
  alias Tracker.Nixpkgs.ChangeTransitions

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case run() do
      :ok -> :ok
      {:ok, _count} -> :ok
      {:snooze, _} = snooze -> snooze
      {:error, _} = error -> error
    end
  end

  @doc """
  Refreshes up to 100 stalest non-terminal Changes against GitHub GraphQL.

  Options:
    * `:fetcher` — 1-arity fn taking a list of node_ids and returning
      `{:ok, %{id => PullRequest | :not_found}}` or `{:error, reason}`.
      Defaults to `Tracker.GitHub.GraphQL.fetch_prs/2`.
    * `:rate_limit_table` — ETS table for the rate-limit cache (tests).
  """
  def run(opts \\ []) do
    Logger.info(msg: "change refresh started")
    started_at = System.monotonic_time()

    table = Keyword.get(opts, :rate_limit_table, RateLimitCache)
    fetcher = Keyword.get_lazy(opts, :fetcher, &default_fetcher/0)
    snoozer = Keyword.get_lazy(opts, :snoozer, fn -> &default_snoozer/0 end)
    on_transition = Keyword.get(opts, :on_transition, &ChangeTransitions.emit/2)

    result =
      case RateLimitCache.check(:graphql, table) do
        {:limited, seconds} ->
          Logger.info(msg: "GraphQL rate limited, skipping refresh", seconds: seconds)
          {:rate_limited, seconds}

        :ok ->
          sweep_dormant!()
          do_run(fetcher, snoozer, on_transition)
      end

    log_finished(result, started_at)
    return_value(result)
  end

  defp return_value({:rate_limited, _seconds}), do: :ok
  defp return_value({:ok, _summary} = ok), do: {:ok, ok |> elem(1) |> Map.fetch!(:checked)}
  defp return_value({:snooze, _} = s), do: s
  defp return_value({:error, _} = e), do: e

  defp log_finished({:rate_limited, seconds}, started_at) do
    Logger.info(
      msg: "change refresh finished",
      outcome: :rate_limited,
      skip_seconds: seconds,
      duration_ms: duration_ms(started_at)
    )
  end

  defp log_finished({:ok, summary}, started_at) do
    Logger.info(
      msg: "change refresh finished",
      outcome: :ok,
      checked: summary.checked,
      merged: summary.merged,
      head_sha_changed: summary.head_sha_changed,
      closed_no_merge: summary.closed_no_merge,
      not_found: summary.not_found,
      duration_ms: duration_ms(started_at)
    )
  end

  defp log_finished({:snooze, seconds}, started_at) do
    Logger.info(
      msg: "change refresh finished",
      outcome: :snoozed,
      snooze_seconds: seconds,
      duration_ms: duration_ms(started_at)
    )
  end

  defp log_finished({:error, reason}, started_at) do
    Logger.info(
      msg: "change refresh finished",
      outcome: :error,
      reason: inspect(reason),
      duration_ms: duration_ms(started_at)
    )
  end

  defp duration_ms(started_at) do
    System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)
  end

  defp default_fetcher do
    fn ids -> Tracker.GitHub.GraphQL.fetch_prs(ids, []) end
  end

  defp sweep_dormant! do
    cutoff = DateTime.utc_now() |> DateTime.add(-@dormancy_threshold_days, :day)
    Change.mark_stale_dormant!(cutoff)
  end

  defp default_snoozer do
    token = Tracker.GitHub.installation_token!()
    Tracker.GitHub.seconds_until_reset(token, :graphql)
  end

  defp do_run(fetcher, snoozer, on_transition) do
    case Change.stalest_unfinished!() do
      [] ->
        {:ok, empty_summary()}

      changes ->
        node_ids = Enum.map(changes, & &1.node_id)

        case fetcher.(node_ids) do
          {:ok, results} ->
            apply_results(changes, results, on_transition)

          {:error, %GitHub.Error{reason: :rate_limited}} ->
            snooze = snoozer.()
            Logger.warning(msg: "GraphQL rate limited, snoozing refresh worker", seconds: snooze)
            {:snooze, snooze}

          {:error, reason} = error ->
            Logger.error(msg: "ChangeRefreshWorker fetch failed", reason: inspect(reason))
            error
        end
    end
  end

  defp apply_results(changes, results, on_transition) do
    summary =
      Enum.reduce(changes, empty_summary(), fn change, acc ->
        case Map.fetch!(results, change.node_id) do
          :not_found ->
            Logger.warning(
              msg: "refresh got not_found",
              number: change.number,
              node_id: change.node_id
            )

            Change.mark_not_found!(change)
            increment(acc, [:checked, :not_found])

          %PullRequest{} = pr ->
            transitions = apply_pr(change, pr, on_transition)

            transitions
            |> Enum.reduce(increment(acc, [:checked]), fn t, a -> increment(a, [t]) end)
        end
      end)

    {:ok, summary}
  end

  defp apply_pr(change, pr, on_transition) do
    attrs = %{
      state: pr.state,
      base_ref: pr.base_ref,
      head_ref: pr.head_ref,
      head_sha: pr.head_sha,
      title: pr.title,
      labels: pr.labels,
      gh_updated_at: pr.updated_at,
      closed_at: pr.closed_at,
      merged_at: pr.merged_at,
      merge_commit_sha: pr.merge_commit_sha
    }

    updated = Change.refresh_from_graphql!(change, attrs)
    transitions = ChangeTransitions.detect(change, pr)
    Enum.each(transitions, &on_transition.(updated, &1))
    transitions
  end

  defp empty_summary,
    do: %{checked: 0, merged: 0, head_sha_changed: 0, closed_no_merge: 0, not_found: 0}

  defp increment(summary, keys) do
    Enum.reduce(keys, summary, fn key, acc -> Map.update!(acc, key, &(&1 + 1)) end)
  end
end

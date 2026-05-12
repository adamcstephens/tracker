defmodule Tracker.Nixpkgs.ChangeReconcileWorker do
  @moduledoc """
  Defense-in-depth backstop for PR discovery.

  Walks the `changes` table for **number gaps** between a configurable lower
  bound and `MAX(number)`, then resolves each gap against GitHub's
  `issueOrPullRequest(number:)` lookup. PRs we'd missed get upserted via the
  same path as discovery; Issues and deleted/transferred numbers land in
  `change_reconcile_skips` so we never re-resolve them.

  Independent of the search-API-anchored discovery path, so it catches PRs
  the search index dropped or never surfaced.
  """
  use Oban.Worker, queue: :changes, max_attempts: 3

  require Logger

  alias Tracker.GitHub.GraphQL
  alias Tracker.Nixpkgs.Change
  alias Tracker.Nixpkgs.ChangeDiscoveryWorker
  alias Tracker.Nixpkgs.ChangeReconcileSkip

  @repo "NixOS/nixpkgs"
  @batch_size 100
  @chunk_size 25
  @floor_window 5_000

  @type summary :: %{
          gaps_found: non_neg_integer(),
          checked: non_neg_integer(),
          prs_recovered: non_neg_integer(),
          skipped: non_neg_integer()
        }

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Tracker.GitHub.RateLimitCache.check(:graphql) do
      {:limited, seconds} ->
        Logger.info(msg: "rate limited, skipping reconcile", seconds: seconds)
        :ok

      :ok ->
        token = Tracker.GitHub.installation_token!()

        case reconcile_gaps(default_fetcher(token), []) do
          {:ok, _summary} ->
            :ok

          {:error, %GitHub.Error{reason: :rate_limited}} ->
            snooze_seconds = Tracker.GitHub.seconds_until_reset(token, :graphql)

            Logger.warning(
              msg: "GitHub GraphQL rate limited, snoozing reconcile worker",
              seconds: snooze_seconds
            )

            {:snooze, snooze_seconds}

          {:error, reason} ->
            Logger.error(msg: "reconcile failed", reason: inspect(reason))
            {:error, reason}
        end
    end
  end

  @doc """
  Investigates a batch of number-space gaps and routes each through the
  appropriate sink (PR upsert vs. skip-table record).

  `fetcher` is `(numbers :: [pos_integer()]) ->
    {:ok, %{number => {:pull_request, %PullRequest{}} | :issue | :not_found}}
    | {:error, term}`.

  Options:
    * `:floor` — lower bound. Defaults to the configured
      `:tracker, :reconcile_floor_number`, or `MAX(number) - #{@floor_window}`.
    * `:batch_size` — max gaps to investigate per run. Default #{@batch_size}.

  Returns `{:ok, summary}` or `{:error, reason}`.
  """
  @spec reconcile_gaps((list(pos_integer()) -> {:ok, map()} | {:error, term}), keyword) ::
          {:ok, summary} | {:error, term}
  def reconcile_gaps(fetcher, opts) when is_function(fetcher, 1) do
    batch_size = Keyword.get(opts, :batch_size, @batch_size)
    max_number = Change.max_number!()
    floor = if max_number, do: resolve_floor(opts, max_number), else: nil
    Logger.info(msg: "change reconcile started", floor: floor, max_number: max_number)
    started_at = System.monotonic_time()

    result =
      cond do
        is_nil(max_number) -> {:ok, empty_summary()}
        floor > max_number -> {:ok, empty_summary()}
        true -> run(fetcher, floor, max_number, batch_size)
      end

    log_finished(result, started_at)
    result
  end

  defp log_finished({:ok, summary}, started_at) do
    Logger.info(
      msg: "change reconcile finished",
      outcome: :ok,
      gaps_found: summary.gaps_found,
      checked: summary.checked,
      prs_recovered: summary.prs_recovered,
      skipped: summary.skipped,
      duration_ms: duration_ms(started_at)
    )
  end

  defp log_finished({:error, reason}, started_at) do
    Logger.info(
      msg: "change reconcile finished",
      outcome: :error,
      reason: inspect(reason),
      duration_ms: duration_ms(started_at)
    )
  end

  defp duration_ms(started_at) do
    System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)
  end

  defp run(fetcher, lo, hi, batch_size) do
    gaps = find_gaps(lo, hi, batch_size)

    case gaps do
      [] ->
        {:ok, empty_summary()}

      _ ->
        case investigate(fetcher, gaps) do
          {:ok, summary} ->
            emit_telemetry(summary)
            warn_on_recovery(summary)
            {:ok, summary}

          {:error, _} = error ->
            error
        end
    end
  end

  defp find_gaps(lo, hi, limit) do
    existing_changes =
      Change.numbers_in_range!(lo, hi)
      |> MapSet.new(& &1.number)

    existing_skips =
      ChangeReconcileSkip.numbers_in_range!(lo, hi)
      |> MapSet.new(& &1.number)

    lo..hi
    |> Stream.reject(&MapSet.member?(existing_changes, &1))
    |> Stream.reject(&MapSet.member?(existing_skips, &1))
    |> Enum.sort(:desc)
    |> Enum.take(limit)
  end

  defp investigate(fetcher, gaps) do
    gaps
    |> Enum.chunk_every(@chunk_size)
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, acc} ->
      case fetcher.(chunk) do
        {:ok, result} when is_map(result) ->
          {:cont, {:ok, [result | acc]}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, results} ->
        merged = results |> Enum.reverse() |> Enum.reduce(%{}, &Map.merge(&2, &1))
        {:ok, route(gaps, merged)}

      {:error, _} = error ->
        error
    end
  end

  defp route(gaps, resolutions) do
    {prs, skips} =
      Enum.reduce(gaps, {[], []}, fn n, {prs, skips} ->
        case Map.get(resolutions, n) do
          {:pull_request, pr} -> {[pr | prs], skips}
          :issue -> {prs, [%{number: n, kind: :issue} | skips]}
          :not_found -> {prs, [%{number: n, kind: :not_found} | skips]}
          nil -> {prs, skips}
        end
      end)

    prs = Enum.reverse(prs)
    skips = Enum.reverse(skips)

    {:ok, _} = ChangeDiscoveryWorker.upsert_pulls(prs)
    :ok = ChangeReconcileSkip.record!(skips)

    %{
      gaps_found: length(gaps),
      checked: length(gaps),
      prs_recovered: length(prs),
      skipped: length(skips)
    }
  end

  defp resolve_floor(opts, max_number) do
    case Keyword.fetch(opts, :floor) do
      {:ok, n} when is_integer(n) ->
        n

      :error ->
        case Application.get_env(:tracker, :reconcile_floor_number) do
          n when is_integer(n) -> n
          _ -> max(max_number - @floor_window, 1)
        end
    end
  end

  defp emit_telemetry(summary) do
    :telemetry.execute(
      [:tracker, :reconcile, :run],
      Map.take(summary, [:checked, :gaps_found, :prs_recovered, :skipped]),
      %{}
    )
  end

  defp warn_on_recovery(%{prs_recovered: n} = summary) when n > 0 do
    Logger.warning(
      msg: "reconcile recovered PRs missed by discovery — investigate",
      prs_recovered: summary.prs_recovered,
      checked: summary.checked
    )
  end

  defp warn_on_recovery(_), do: :ok

  defp empty_summary,
    do: %{gaps_found: 0, checked: 0, prs_recovered: 0, skipped: 0}

  defp default_fetcher(token) do
    fn numbers ->
      numbers
      |> Enum.chunk_every(@chunk_size)
      |> Enum.reduce_while({:ok, %{}}, fn chunk, {:ok, acc} ->
        case GraphQL.fetch_numbers(@repo, chunk, token: token) do
          {:ok, m} -> {:cont, {:ok, Map.merge(acc, m)}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end
end

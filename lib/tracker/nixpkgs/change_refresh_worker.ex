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

  alias Tracker.GitHub.GraphQL.PullRequest
  alias Tracker.GitHub.RateLimitCache
  alias Tracker.Nixpkgs.Change
  alias Tracker.Nixpkgs.ChangePackage

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
    table = Keyword.get(opts, :rate_limit_table, RateLimitCache)
    fetcher = Keyword.get_lazy(opts, :fetcher, &default_fetcher/0)
    snoozer = Keyword.get_lazy(opts, :snoozer, fn -> &default_snoozer/0 end)
    on_transition = Keyword.get(opts, :on_transition, &log_transition/2)

    case RateLimitCache.check(:graphql, table) do
      {:limited, seconds} ->
        Logger.info("GraphQL rate limited for #{seconds}s, skipping refresh")
        :ok

      :ok ->
        do_run(fetcher, snoozer, on_transition)
    end
  end

  defp default_fetcher do
    fn ids -> Tracker.GitHub.GraphQL.fetch_prs(ids, []) end
  end

  defp default_snoozer do
    token = Tracker.GitHub.installation_token!()
    Tracker.GitHub.seconds_until_reset(token, :graphql)
  end

  defp do_run(fetcher, snoozer, on_transition) do
    case Change.stalest_unfinished!() do
      [] ->
        {:ok, 0}

      changes ->
        node_ids = Enum.map(changes, & &1.node_id)

        case fetcher.(node_ids) do
          {:ok, results} ->
            apply_results(changes, results, on_transition)

          {:error, %GitHub.Error{reason: :rate_limited}} ->
            snooze = snoozer.()
            Logger.warning("GraphQL rate limited, snoozing refresh worker #{snooze}s")
            {:snooze, snooze}

          {:error, reason} = error ->
            Logger.error("ChangeRefreshWorker fetch failed: #{inspect(reason)}")
            error
        end
    end
  end

  defp apply_results(changes, results, on_transition) do
    Enum.each(changes, fn change ->
      case Map.fetch!(results, change.node_id) do
        :not_found ->
          Logger.warning(
            msg: "refresh got not_found",
            number: change.number,
            node_id: change.node_id
          )

          Change.touch_last_checked!(change)

        %PullRequest{} = pr ->
          apply_pr(change, pr, on_transition)
      end
    end)

    {:ok, length(changes)}
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

    change
    |> detect_transitions(pr)
    |> Enum.each(&on_transition.(updated, &1))

    updated
  end

  defp detect_transitions(%{state: prior_state, head_sha: prior_sha}, %PullRequest{} = pr) do
    []
    |> maybe_add(prior_state != :merged and pr.state == :merged, :merged)
    |> maybe_add(
      pr.state in [:open, :draft] and prior_sha != pr.head_sha,
      :head_sha_changed
    )
    |> maybe_add(
      prior_state in [:open, :draft] and pr.state == :closed and is_nil(pr.merged_at),
      :closed_no_merge
    )
  end

  defp maybe_add(list, true, tag), do: [tag | list]
  defp maybe_add(list, false, _), do: list

  defp log_transition(change, reason) when reason in [:merged, :head_sha_changed] do
    Logger.info(
      msg: "artifact_refresh transition detected",
      number: change.number,
      node_id: change.node_id,
      reason: reason
    )

    %{"number" => change.number, "reason" => Atom.to_string(reason)}
    |> Tracker.Nixpkgs.ChangeArtifactRefreshWorker.new()
    |> Oban.insert!()

    :ok
  end

  defp log_transition(change, :closed_no_merge) do
    Logger.info(
      msg: "clearing ChangePackage links for closed-without-merge PR",
      number: change.number,
      node_id: change.node_id
    )

    {:ok, notifications} =
      Tracker.Repo.transaction(fn ->
        ChangePackage.clear_for_change!(change.id)

        {_, notifications} =
          Change.update_package_count!(
            change,
            %{package_count: 0},
            return_notifications?: true
          )

        notifications
      end)

    Ash.Notifier.notify(notifications)
    :ok
  end
end

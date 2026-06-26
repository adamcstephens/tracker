defmodule Tracker.Nixpkgs.ChangeBranchDetectionWorker do
  @moduledoc """
  Detects when merged Changes have propagated into intermediate
  downstream branches (`staging`, `staging-next`, `master`,
  `release-X.Y`, …) and records the arrival as `ChangeBranch` rows.

  Channel-kind branches (`nixos-*`, `nixpkgs-*`) are owned by
  `Tracker.Nixpkgs.ChannelRevisionLinkWorker`, which links them against
  a specific `ChannelRevision` rather than a moving branch tip. This
  worker explicitly excludes them from its check list.

  Enqueued from `Tracker.Ingestion.Steps.CreateRevision` once a fresh
  `ChannelRevision` lands. Ingestion implies a recent `git fetch`, so
  every branch tip in the propagation DAG is current.

  For each in-flight Change (merged, with a `merge_commit_sha` and
  `base_ref` in the propagation graph, not yet covering `base_ref` and
  every terminal channel reachable from it), the worker fans out
  per-change using `Task.async_stream` over the non-channel branches
  in `[base_ref | Propagation.downstream(base_ref)]`, reusing a single
  `GitServer` snapshot. The `base_ref` itself is included so the merge
  target is seeded on the first run, even when the open→merged
  transition was applied via `bulk_upsert_all` (which bypasses Ash
  actions).
  """
  use Oban.Worker, queue: :branch_detection, max_attempts: 5, unique: [period: 60]

  require Logger

  alias Tracker.GitServer
  alias Tracker.Nixpkgs.Change
  alias Tracker.Nixpkgs.ChangeBranch
  alias Tracker.Nixpkgs.Propagation

  @max_concurrency 8
  @ancestor_timeout :timer.seconds(30)

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: run()

  @doc """
  Runs detection over all in-flight Changes.

  Options:
    * `:git_server` — `GenServer.server()` for the `GitServer` instance
      (defaults to the named `Tracker.GitServer`).
  """
  def run(opts \\ []) do
    Logger.info(msg: "branch detection started")
    started_at = System.monotonic_time()
    git_server = Keyword.get(opts, :git_server, Tracker.GitServer)

    fetch_failed? =
      case GitServer.fetch(git_server) do
        :ok ->
          false

        {:error, reason} ->
          Logger.warning(
            msg: "ChangeBranchDetectionWorker: fetch failed; proceeding with current refs",
            reason: inspect(reason)
          )

          true
      end

    snapshot = GitServer.state(git_server)

    if snapshot.ready do
      in_flight = Change.in_flight_propagation!()

      pairs =
        in_flight
        |> Enum.flat_map(&pending_branches/1)

      branches_recorded =
        pairs
        |> Task.async_stream(
          fn {change, branch} -> detect(change, branch, snapshot) end,
          max_concurrency: @max_concurrency,
          timeout: @ancestor_timeout,
          on_timeout: :kill_task
        )
        |> Enum.count(&match?({:ok, :recorded}, &1))

      Logger.info(
        msg: "branch detection finished",
        outcome: :ok,
        in_flight: length(in_flight),
        branches_checked: length(pairs),
        branches_recorded: branches_recorded,
        fetch_failed?: fetch_failed?,
        duration_ms: duration_ms(started_at)
      )

      :ok
    else
      Logger.warning(msg: "ChangeBranchDetectionWorker: GitServer not ready, snoozing")

      Logger.info(
        msg: "branch detection finished",
        outcome: :snoozed,
        snooze_seconds: 30,
        fetch_failed?: fetch_failed?,
        duration_ms: duration_ms(started_at)
      )

      {:snooze, 30}
    end
  end

  defp duration_ms(started_at) do
    System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)
  end

  defp pending_branches(change) do
    if Propagation.valid_branch?(change.base_ref) do
      recorded = MapSet.new(change.change_branches, & &1.branch_name)
      covered = MapSet.new([change.base_ref | Propagation.terminal_channels(change.base_ref)])

      if MapSet.subset?(covered, recorded) do
        []
      else
        [change.base_ref | Propagation.downstream(change.base_ref)]
        |> Enum.reject(&(Propagation.kind(&1) == :channel))
        |> Enum.reject(&MapSet.member?(recorded, &1))
        |> Enum.map(&{change, &1})
      end
    else
      []
    end
  end

  defp detect(change, branch, snapshot) do
    case GitServer.ancestor?(change.merge_commit_sha, "refs/heads/#{branch}", snapshot) do
      {:ok, true} ->
        ChangeBranch.create!(%{change_id: change.id, branch_name: branch})

        :recorded

      {:ok, false} ->
        :no_match

      {:error, reason} ->
        Logger.warning(
          msg: "ChangeBranchDetectionWorker: ancestor check failed",
          change_number: change.number,
          branch: branch,
          reason: inspect(reason)
        )

        :ancestor_error
    end
  end
end

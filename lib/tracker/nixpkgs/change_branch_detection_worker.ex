defmodule Tracker.Nixpkgs.ChangeBranchDetectionWorker do
  @moduledoc """
  Detects when merged Changes have propagated into downstream branches and
  records the arrival as `ChangeBranch` rows.

  Enqueued from `Tracker.Ingestion.Steps.CreateRevision` once a fresh
  `ChannelRevision` lands. Ingestion implies a recent `git fetch`, so
  every branch tip in the propagation DAG is current.

  For each in-flight Change (merged, with a `merge_commit_sha` and
  `base_ref` in the propagation graph, not yet covering all terminal
  channels reachable from `base_ref`), the worker fans out per-change
  using `Task.async_stream` over `Propagation.downstream(base_ref)`,
  reusing a single `GitServer` snapshot.
  """
  use Oban.Worker, queue: :ingestion, max_attempts: 5, unique: [period: 60]

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
    git_server = Keyword.get(opts, :git_server, Tracker.GitServer)
    snapshot = GitServer.state(git_server)

    if snapshot.ready do
      Change.in_flight_propagation!()
      |> Stream.flat_map(&pending_branches/1)
      |> Task.async_stream(
        fn {change, branch} -> detect(change, branch, snapshot) end,
        max_concurrency: @max_concurrency,
        timeout: @ancestor_timeout,
        on_timeout: :kill_task
      )
      |> Stream.run()

      :ok
    else
      Logger.warning("ChangeBranchDetectionWorker: GitServer not ready, snoozing")
      {:snooze, 30}
    end
  end

  defp pending_branches(change) do
    if Propagation.valid_branch?(change.base_ref) do
      recorded = MapSet.new(change.change_branches, & &1.branch_name)
      terminals = MapSet.new(Propagation.terminal_channels(change.base_ref))

      if MapSet.subset?(terminals, recorded) do
        []
      else
        change.base_ref
        |> Propagation.downstream()
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

        :ok

      {:ok, false} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          msg: "ChangeBranchDetectionWorker: ancestor check failed",
          change_number: change.number,
          branch: branch,
          reason: inspect(reason)
        )

        :ok
    end
  end
end

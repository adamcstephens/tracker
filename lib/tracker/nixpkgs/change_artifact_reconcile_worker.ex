defmodule Tracker.Nixpkgs.ChangeArtifactReconcileWorker do
  @moduledoc """
  Recovers pending and transiently failed artifact ingestion for merged,
  open, and draft Changes. Matching incomplete jobs are excluded before
  limiting the backlog so in-flight work cannot consume the batch.
  """
  use Oban.Worker, queue: :changes, max_attempts: 3

  import Ecto.Query

  require Logger

  alias Tracker.Nixpkgs.Change
  alias Tracker.Nixpkgs.ChangeArtifactRefreshWorker

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.info(msg: "artifact reconcile started")
    started_at = System.monotonic_time()

    result = run()
    {outcome, enqueued} = summarize(result)

    Logger.info(
      msg: "artifact reconcile finished",
      outcome: outcome,
      enqueued: enqueued,
      duration_ms: duration_ms(started_at)
    )

    result
  end

  @doc """
  Enqueues up to 50 eligible artifact refreshes.
  Returns `{:ok, enqueued_count}`, excluding uniqueness conflicts.
  """
  def run do
    worker = Oban.Worker.to_string(ChangeArtifactRefreshWorker)
    states = Enum.map(Oban.Job.unique_states(:incomplete), &to_string/1)

    {merged, head} =
      Tracker.Repo.all(
        from job in Oban.Job,
          where: job.worker == ^worker and job.state in ^states,
          where: job.args["reason"] in ^["merged", "head_sha_changed"],
          select: job.args
      )
      |> Enum.split_with(&(&1["reason"] == "merged"))

    backlog =
      Change.artifact_backlog!(
        Enum.map(merged, & &1["number"]),
        Enum.map(head, & &1["number"])
      )

    count =
      Enum.reduce(backlog, 0, fn change, count ->
        reason = if change.state == :merged, do: "merged", else: "head_sha_changed"

        job =
          %{"number" => change.number, "reason" => reason}
          |> ChangeArtifactRefreshWorker.new(
            unique: [
              fields: [:worker, :args],
              keys: [:number, :reason],
              period: :infinity,
              states: :incomplete
            ]
          )
          |> Oban.insert!()

        if job.conflict?, do: count, else: count + 1
      end)

    {:ok, count}
  end

  defp summarize({:ok, count}), do: {:ok, count}

  defp duration_ms(started_at) do
    System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)
  end
end

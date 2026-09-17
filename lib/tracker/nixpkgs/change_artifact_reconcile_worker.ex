defmodule Tracker.Nixpkgs.ChangeArtifactReconcileWorker do
  @moduledoc """
  Recovers pending and transiently failed artifact ingestion for merged,
  open, and draft Changes. Each batch reserves capacity for merged and
  head refreshes after excluding matching incomplete jobs.
  """
  use Oban.Worker, queue: :changes, max_attempts: 3

  @batch_size 50
  @reserved_per_category div(@batch_size, 2)

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

    merged_backlog =
      merged
      |> Enum.map(& &1["number"])
      |> Change.merged_artifact_backlog!()

    head_backlog =
      head
      |> Enum.map(& &1["number"])
      |> Change.head_artifact_backlog!()

    backlog = balance_backlog(merged_backlog, head_backlog)

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

  defp balance_backlog(merged, head) do
    {selected_merged, remaining_merged} = Enum.split(merged, @reserved_per_category)
    {selected_head, remaining_head} = Enum.split(head, @reserved_per_category)

    remaining_capacity =
      @batch_size - length(selected_merged) - length(selected_head)

    selected_merged ++
      selected_head ++ Enum.take(remaining_merged ++ remaining_head, remaining_capacity)
  end

  defp summarize({:ok, count}), do: {:ok, count}

  defp duration_ms(started_at) do
    System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)
  end
end

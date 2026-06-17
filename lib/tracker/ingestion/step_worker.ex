defmodule Tracker.Ingestion.StepWorker do
  @moduledoc """
  Single Oban worker that dispatches ingestion pipeline steps.

  Each job runs one step for one pipeline. On success, atomically
  appends the step to `completed_steps`, computes newly ready
  downstream steps, and enqueues them. On final failure, marks the
  pipeline as failed.
  """

  use Oban.Worker,
    queue: :ingestion,
    max_attempts: 5,
    unique: [keys: [:pipeline_id, :step]]

  require Logger

  alias Tracker.Ingestion.{Pipeline, StepContext, StepGraph}

  @task_supervisor Tracker.Ingestion.StepTaskSupervisor

  # `run_isolated/2` enforces the per-step timeout itself; this Oban-level timeout
  # is a generous backstop in case the worker wedges outside the isolated task.
  @timeout_backstop :timer.seconds(30)

  @impl Oban.Worker
  def timeout(%Oban.Job{args: %{"step" => step_name}}) do
    step = String.to_existing_atom(step_name)
    StepGraph.step_module(step).timeout() + @timeout_backstop
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"pipeline_id" => pipeline_id, "step" => step_name}} = job) do
    Logger.info(
      msg: "step started",
      pipeline_id: pipeline_id,
      step: step_name,
      channel_id: job.meta["channel_id"],
      revision: job.meta["revision"],
      attempt: job.attempt
    )

    started_at = System.monotonic_time()
    step = String.to_existing_atom(step_name)
    step_module = StepGraph.step_module(step)

    {return_value, summary} =
      case Ash.get(Pipeline, pipeline_id) do
        {:ok, pipeline} ->
          if pipeline.status != :running do
            Logger.info(
              msg: "pipeline not running, skipping step",
              pipeline_id: pipeline_id,
              pipeline_status: pipeline.status,
              step: step_name
            )

            {:ok, %{outcome: :skipped, pipeline_status: pipeline.status}}
          else
            ctx = build_context(pipeline)
            execute_step(step_module, step, ctx, job)
          end

        {:error, _} ->
          Logger.error(msg: "pipeline not found", pipeline_id: pipeline_id)
          {{:error, :pipeline_not_found}, %{outcome: :error, status: :pipeline_not_found}}
      end

    Logger.info(
      [
        msg: "step finished",
        pipeline_id: pipeline_id,
        step: step_name
      ] ++ Enum.to_list(summary) ++ [duration_ms: duration_ms(started_at)]
    )

    return_value
  end

  defp duration_ms(started_at) do
    System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)
  end

  defp build_context(pipeline) do
    channel_revision =
      if pipeline.channel_revision_id do
        case Ash.get(Tracker.Nixpkgs.ChannelRevision, pipeline.channel_revision_id) do
          {:ok, cr} -> cr
          _ -> nil
        end
      end

    %StepContext{pipeline: pipeline, channel_revision: channel_revision}
  end

  defp execute_step(step_module, step, ctx, job) do
    case run_isolated(fn -> step_module.run(ctx) end, step_module.timeout()) do
      :ok ->
        handle_step_success(ctx.pipeline, step)

      {:error, reason} ->
        handle_step_failure(ctx.pipeline, step, reason, job)
    end
  end

  @doc """
  Runs a step function under a supervised, non-linked task and normalizes the
  outcome to `:ok` or `{:error, reason}`.

  A step can fail by returning `{:error, reason}`, by raising, or by crashing a
  linked subtask (e.g. a `Task.async` inside the step). The last case kills the
  task that runs `fun` but — because the task is started `async_nolink` — leaves
  the calling worker alive to record the failure instead of being taken down by
  the link.
  """
  @spec run_isolated((-> :ok | {:error, term()}), timeout()) :: :ok | {:error, term()}
  def run_isolated(fun, timeout) when is_function(fun, 0) do
    task = Task.Supervisor.async_nolink(@task_supervisor, fun)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, other} -> {:error, {:unexpected_step_return, other}}
      {:exit, reason} -> {:error, reason}
      nil -> {:error, {:step_timeout, timeout}}
    end
  end

  defp handle_step_success(pipeline, step) do
    updated_pipeline = Pipeline.complete_step!(pipeline, step)

    ready =
      StepGraph.ready_steps(
        atomize_list(updated_pipeline.active_steps),
        atomize_list(updated_pipeline.completed_steps)
      )

    {pipeline_status, next_steps} =
      if ready == [] and all_complete?(updated_pipeline) do
        Pipeline.mark_completed!(updated_pipeline)
        start_next_pipeline(updated_pipeline)
        {:completed, 0}
      else
        Enum.each(ready, fn next_step ->
          enqueue(updated_pipeline, next_step)
        end)

        {updated_pipeline.status, length(ready)}
      end

    {:ok, %{outcome: :ok, next_steps: next_steps, pipeline_status: pipeline_status}}
  end

  defp handle_step_failure(pipeline, step, reason, job) do
    {pipeline_status, final?} =
      if job.attempt >= job.max_attempts do
        error_msg = inspect(reason, limit: 500)

        Pipeline.mark_failed!(pipeline, step, error_msg)

        Logger.error(
          msg: "pipeline failed at step",
          pipeline_id: pipeline.id,
          step: step,
          error: error_msg
        )

        {:failed, true}
      else
        {pipeline.status, false}
      end

    summary = %{
      outcome: :error,
      pipeline_status: pipeline_status,
      reason: inspect(reason),
      final?: final?
    }

    {{:error, reason}, summary}
  end

  defp all_complete?(pipeline) do
    active = MapSet.new(atomize_list(pipeline.active_steps))
    completed = MapSet.new(atomize_list(pipeline.completed_steps))
    MapSet.equal?(active, completed)
  end

  defp start_next_pipeline(completed_pipeline) do
    case Pipeline.next_pending_for_channel!(completed_pipeline.channel_id) do
      [next | _] ->
        if startable?(next) do
          Pipeline.start!(next)
          enqueue(next, :create_revision)
        else
          check_run_completion(completed_pipeline)
        end

      [] ->
        check_run_completion(completed_pipeline)
    end
  end

  defp startable?(pipeline) do
    case pipeline.predecessor_id do
      nil ->
        true

      predecessor_id ->
        case Ash.get(Pipeline, predecessor_id) do
          {:ok, %{status: :completed}} -> true
          _ -> false
        end
    end
  end

  defp check_run_completion(pipeline) do
    pipelines = Pipeline.for_run!(pipeline.ingestion_run_id)

    all_done =
      Enum.all?(pipelines, fn p ->
        p.status in [:completed, :failed]
      end)

    if all_done do
      run = Ash.get!(Tracker.Ingestion.IngestionRun, pipeline.ingestion_run_id)

      has_failures = Enum.any?(pipelines, &(&1.status == :failed))

      if has_failures do
        Tracker.Ingestion.IngestionRun.mark_failed!(run)
      else
        Tracker.Ingestion.IngestionRun.mark_completed!(run)
      end
    end
  end

  @doc """
  Enqueues a StepWorker job for the given pipeline and step.
  """
  def enqueue(pipeline, step) do
    %{"pipeline_id" => pipeline.id, "step" => to_string(step)}
    |> new(
      meta: %{
        "channel_id" => pipeline.channel_id,
        "revision" => String.slice(pipeline.revision, 0, 7)
      }
    )
    |> Oban.insert!()
  end

  defp atomize_list(list) do
    Enum.map(list, fn
      item when is_atom(item) -> item
      item when is_binary(item) -> String.to_existing_atom(item)
    end)
  end
end

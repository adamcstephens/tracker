defmodule Tracker.Ingestion.StepWorkerTest do
  use Tracker.DataCase, async: true

  alias Tracker.Ingestion.{IngestionRun, Pipeline, StepWorker}
  alias Tracker.Nixpkgs.Channel

  describe "run_isolated/2" do
    test "passes through a step's :ok result" do
      assert :ok == StepWorker.run_isolated(fn -> :ok end, 1_000)
    end

    test "passes through a step's {:error, reason} result" do
      assert {:error, :boom} == StepWorker.run_isolated(fn -> {:error, :boom} end, 1_000)
    end

    test "turns a raised exception into {:error, _} without killing the caller" do
      assert {:error, _} = StepWorker.run_isolated(fn -> raise "boom" end, 1_000)
      assert Process.alive?(self())
    end

    test "contains a crash from an internal linked Task.async" do
      # This is the failure mode that bypasses try/rescue: a linked subtask crash
      # would otherwise kill the worker process via the link.
      fun = fn ->
        Map.new()
        |> Task.async(fn -> Map.fetch!(%{}, :missing) end)
        |> Task.await()
      end

      assert {:error, _} = StepWorker.run_isolated(fun, 1_000)
      assert Process.alive?(self())
    end

    test "turns a timeout into {:error, {:step_timeout, _}} and kills the work" do
      assert {:error, {:step_timeout, 50}} =
               StepWorker.run_isolated(fn -> Process.sleep(:infinity) end, 50)
    end
  end

  describe "perform/1 with a crashing step" do
    setup do
      channel =
        Channel.create!(%{
          name: "nixos-unstable",
          display_name: "NixOS Unstable",
          status: :active,
          is_stable: false
        })

      run = IngestionRun.create!(%{type: :cron_update, started_at: DateTime.utc_now()})

      # No channel_revision_id is set, so build_context yields a nil channel_revision
      # and the finalize step crashes on `record_result!(nil, ...)` mid-step.
      pipeline =
        Pipeline.create!(%{
          channel_id: channel.id,
          revision: "rev",
          base_url: "https://example.invalid/x",
          released_at: DateTime.utc_now(),
          active_steps: [:finalize],
          sequence: 0,
          ingestion_run_id: run.id
        })
        |> Pipeline.start!()

      {:ok, pipeline: pipeline}
    end

    defp job(pipeline, attempt) do
      %Oban.Job{
        args: %{"pipeline_id" => pipeline.id, "step" => "finalize"},
        attempt: attempt,
        max_attempts: 5,
        meta: %{}
      }
    end

    test "marks the pipeline :failed on the final attempt instead of stalling", %{
      pipeline: pipeline
    } do
      assert {:error, _} = StepWorker.perform(job(pipeline, 5))

      reloaded = Ash.get!(Pipeline, pipeline.id)
      assert reloaded.status == :failed
      assert reloaded.failed_step == :finalize
    end

    test "keeps the pipeline :running and retries before the final attempt", %{
      pipeline: pipeline
    } do
      assert {:error, _} = StepWorker.perform(job(pipeline, 1))

      reloaded = Ash.get!(Pipeline, pipeline.id)
      assert reloaded.status == :running
    end
  end
end

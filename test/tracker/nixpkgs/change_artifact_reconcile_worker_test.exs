defmodule Tracker.Nixpkgs.ChangeArtifactReconcileWorkerTest do
  use Tracker.DataCase, async: false

  import ExUnit.CaptureLog

  require Logger

  alias Tracker.Nixpkgs.Change
  alias Tracker.Nixpkgs.ChangeArtifactReconcileWorker
  alias Tracker.Nixpkgs.ChangeArtifactRefreshWorker

  describe "run/0" do
    test "enqueues refresh for merged+pending Changes, skips others" do
      insert_change!(number: 7001, state: :merged, processing_status: :pending)
      insert_change!(number: 7002, state: :merged, processing_status: :processed)
      insert_change!(number: 7003, state: :open, processing_status: :pending)
      insert_change!(number: 7004, state: :closed, processing_status: :pending)
      insert_change!(number: 7005, state: :merged, processing_status: :too_large)

      assert {:ok, 1} = ChangeArtifactReconcileWorker.run()

      assert_enqueued(
        worker: ChangeArtifactRefreshWorker,
        args: %{"number" => 7001, "reason" => "merged"}
      )

      for n <- [7002, 7003, 7004, 7005] do
        refute_enqueued(worker: ChangeArtifactRefreshWorker, args: %{"number" => n})
      end
    end

    test "returns {:ok, 0} when backlog is empty" do
      assert {:ok, 0} = ChangeArtifactReconcileWorker.run()
      refute_enqueued(worker: ChangeArtifactRefreshWorker)
    end

    test "orders by merged_at asc (oldest first) and respects the 50-row cap" do
      # Insert 55 merged+pending Changes with staggered merged_at timestamps
      for i <- 1..55 do
        insert_change!(
          number: 8000 + i,
          state: :merged,
          processing_status: :pending,
          merged_at: DateTime.add(~U[2026-04-01 00:00:00Z], i, :second)
        )
      end

      assert {:ok, 50} = ChangeArtifactReconcileWorker.run()

      # Oldest 50 (merged_at seconds +1..+50) should be enqueued;
      # newest 5 (+51..+55) should not.
      for i <- 1..50 do
        assert_enqueued(
          worker: ChangeArtifactRefreshWorker,
          args: %{"number" => 8000 + i}
        )
      end

      for i <- 51..55 do
        refute_enqueued(
          worker: ChangeArtifactRefreshWorker,
          args: %{"number" => 8000 + i}
        )
      end
    end

    test "Oban uniqueness: second run within the window does not double-enqueue" do
      insert_change!(number: 9001, state: :merged, processing_status: :pending)

      assert {:ok, 1} = ChangeArtifactReconcileWorker.run()
      assert {:ok, 1} = ChangeArtifactReconcileWorker.run()

      # Only one job in the queue despite two reconcile runs.
      jobs =
        all_enqueued(worker: ChangeArtifactRefreshWorker)
        |> Enum.filter(&(&1.args["number"] == 9001))

      assert length(jobs) == 1
    end

    test "emits structured start/stop logs with outcome and enqueued count" do
      insert_change!(number: 7001, state: :merged, processing_status: :pending)
      Logger.put_module_level(ChangeArtifactReconcileWorker, :info)
      on_exit(fn -> Logger.delete_module_level(ChangeArtifactReconcileWorker) end)

      log =
        capture_log(fn ->
          assert {:ok, 1} = perform_job(ChangeArtifactReconcileWorker, %{}, queue: :changes)
        end)

      assert log =~ ~s(msg: "artifact reconcile started")
      assert log =~ ~s(msg: "artifact reconcile finished")
      assert log =~ "outcome: :ok"
      assert log =~ "enqueued: 1"
      assert log =~ ~r/duration_ms: \d+/
    end
  end

  defp insert_change!(attrs) do
    defaults = [
      title: "test PR",
      state: :merged,
      processing_status: :pending,
      author: "tester",
      url: "https://github.com/NixOS/nixpkgs/pull/#{attrs[:number]}",
      base_ref: "master"
    ]

    record = Keyword.merge(defaults, attrs) |> Map.new()
    Change.bulk_upsert_all([record])
  end
end

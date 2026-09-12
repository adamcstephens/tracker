defmodule Tracker.Nixpkgs.ChangeArtifactReconcileWorkerTest do
  use Tracker.DataCase, async: false

  alias Tracker.Nixpkgs.Change
  alias Tracker.Nixpkgs.ChangeArtifactReconcileWorker
  alias Tracker.Nixpkgs.ChangeArtifactRefreshWorker

  describe "run/0" do
    test "enqueues pending Changes across supported PR states, skips others" do
      insert_change!(number: 7001, state: :merged, processing_status: :pending)
      insert_change!(number: 7002, state: :merged, processing_status: :processed)
      insert_change!(number: 7003, state: :open, processing_status: :pending)
      insert_change!(number: 7004, state: :closed, processing_status: :pending)
      insert_change!(number: 7005, state: :merged, processing_status: :too_large)
      insert_change!(number: 7006, state: :draft, processing_status: :pending)

      assert {:ok, 3} = ChangeArtifactReconcileWorker.run()

      assert_enqueued(
        worker: ChangeArtifactRefreshWorker,
        args: %{"number" => 7001, "reason" => "merged"}
      )

      for n <- [7003, 7006] do
        assert_enqueued(
          worker: ChangeArtifactRefreshWorker,
          args: %{"number" => n, "reason" => "head_sha_changed"}
        )
      end

      for n <- [7002, 7004, 7005] do
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

    test "does not enqueue another refresh while matching work is incomplete" do
      insert_change!(number: 9001, state: :merged, processing_status: :pending)

      assert {:ok, 1} = ChangeArtifactReconcileWorker.run()
      assert {:ok, 0} = ChangeArtifactReconcileWorker.run()

      # Only one job in the queue despite two reconcile runs.
      jobs =
        all_enqueued(worker: ChangeArtifactRefreshWorker)
        |> Enum.filter(&(&1.args["number"] == 9001))

      assert length(jobs) == 1
    end

    test "old incomplete jobs do not consume the batch or allow duplicate refreshes" do
      for {state, i} <- Enum.with_index([:available, :scheduled, :executing, :retryable]) do
        for n <- (i * 15 + 1)..(i * 15 + 15) do
          pr_state = Enum.at([:merged, :open, :draft], rem(n, 3))
          reason = if pr_state == :merged, do: "merged", else: "head_sha_changed"
          insert_change!(number: n, state: pr_state)

          %{"number" => n, "reason" => reason}
          |> ChangeArtifactRefreshWorker.new()
          |> Ecto.Changeset.change(
            state: to_string(state),
            inserted_at: DateTime.add(DateTime.utc_now(), -3600, :second)
          )
          |> Tracker.Repo.insert!()
        end
      end

      insert_change!(number: 100, state: :merged)
      assert {:ok, 1} = ChangeArtifactReconcileWorker.run()
      assert_enqueued(worker: ChangeArtifactRefreshWorker, args: %{"number" => 100})
      assert Tracker.Repo.aggregate(Oban.Job, :count) == 61
    end

    test "terminal outcomes are not retried" do
      for {status, n} <-
            Enum.with_index(
              [
                :artifact_expired,
                :no_workflow_run,
                :no_comparison_artifact,
                :failed_workflow_run,
                :base_ref_skipped,
                :too_large,
                :processed
              ],
              1
            ),
          {state, offset} <- [merged: 0, open: 100, draft: 200] do
        insert_change!(number: n + offset, state: state, processing_status: status)
      end

      assert {:ok, 0} = ChangeArtifactReconcileWorker.run()
      refute_enqueued(worker: ChangeArtifactRefreshWorker)
    end

    for state <- [:merged, :open, :draft] do
      test "recovers exhausted network failures for #{state} PRs" do
        state = unquote(state)
        reason = unquote(if state == :merged, do: "merged", else: "head_sha_changed")
        insert_change!(number: 101, state: state, head_sha: "head", merge_commit_sha: "merge")
        args = %{"number" => 101, "reason" => reason}
        table = :artifact_reconcile_test_rate_limit
        Tracker.GitHub.RateLimitCache.new(table)

        assert {:error, :network_failure} =
                 ChangeArtifactRefreshWorker.run(
                   %{number: 101, reason: reason},
                   attempt: 10,
                   max_attempts: 10,
                   rate_limit_table: table,
                   attrdiff_fetcher: fn _ -> {:error, :network_failure} end
                 )

        args
        |> ChangeArtifactRefreshWorker.new()
        |> Ecto.Changeset.change(state: "discarded", attempt: 10)
        |> Tracker.Repo.insert!()

        assert Change.get_by_number!(101).processing_status == :failed
        assert {:ok, 1} = ChangeArtifactReconcileWorker.run()
        assert_enqueued(worker: ChangeArtifactRefreshWorker, args: args)

        [job] = all_enqueued(worker: ChangeArtifactRefreshWorker)

        assert :ok =
                 ChangeArtifactRefreshWorker.run(
                   %{number: job.args["number"], reason: job.args["reason"]},
                   rate_limit_table: table,
                   attrdiff_fetcher: fn _change ->
                     {:ok, %{"added" => ["recovered-package"]}}
                   end,
                   files_fetcher: fn _ -> {:ok, []} end
                 )

        recovered = Change.get_by_number!(101)
        assert recovered.processing_status == :processed
        assert recovered.package_count == 1
      end
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

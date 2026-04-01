defmodule Tracker.Nixpkgs.ChangePollWorkerTest do
  use Tracker.DataCase, async: true

  alias Tracker.Nixpkgs.ChangePollWorker

  describe "perform/1" do
    test "snoozes when rate limited" do
      error = %GitHub.Error{
        reason: :rate_limited,
        message: "API rate limit exceeded",
        code: 403,
        operation: nil,
        source: nil,
        stacktrace: [],
        step: nil
      }

      assert {:snooze, 60} = ChangePollWorker.handle_fetch_result({:error, error})
    end
  end

  describe "process_pull_requests/1" do
    test "enqueues jobs for merged PRs" do
      pulls = [
        %GitHub.PullRequest{number: 1001, merged_at: ~U[2026-04-01 12:00:00Z]},
        %GitHub.PullRequest{number: 1002, merged_at: ~U[2026-04-01 13:00:00Z]}
      ]

      assert {:ok, 2} = ChangePollWorker.process_pull_requests(pulls)

      assert_enqueued(worker: Tracker.Nixpkgs.ChangeProcessWorker, args: %{"number" => 1001})
      assert_enqueued(worker: Tracker.Nixpkgs.ChangeProcessWorker, args: %{"number" => 1002})
    end

    test "skips PRs that are not merged" do
      pulls = [
        %GitHub.PullRequest{number: 2001, merged_at: nil},
        %GitHub.PullRequest{number: 2002, merged_at: nil}
      ]

      assert {:ok, 0} = ChangePollWorker.process_pull_requests(pulls)

      refute_enqueued(worker: Tracker.Nixpkgs.ChangeProcessWorker)
    end

    test "skips PRs that already have a Change record" do
      Tracker.Nixpkgs.Change.bulk_upsert_all([
        %{
          number: 3001,
          title: "already tracked",
          state: :merged,
          author: "alice",
          url: "https://github.com/NixOS/nixpkgs/pull/3001"
        }
      ])

      pulls = [
        %GitHub.PullRequest{number: 3001, merged_at: ~U[2026-04-01 12:00:00Z]},
        %GitHub.PullRequest{number: 3002, merged_at: ~U[2026-04-01 13:00:00Z]}
      ]

      assert {:ok, 1} = ChangePollWorker.process_pull_requests(pulls)

      refute_enqueued(worker: Tracker.Nixpkgs.ChangeProcessWorker, args: %{"number" => 3001})
      assert_enqueued(worker: Tracker.Nixpkgs.ChangeProcessWorker, args: %{"number" => 3002})
    end
  end
end

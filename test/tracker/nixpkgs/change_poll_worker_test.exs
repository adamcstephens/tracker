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
        %{
          "number" => 1001,
          "state" => "closed",
          "merged_at" => "2026-04-01T12:00:00Z",
          "title" => "fix: something"
        },
        %{
          "number" => 1002,
          "state" => "closed",
          "merged_at" => "2026-04-01T13:00:00Z",
          "title" => "feat: add thing"
        }
      ]

      assert {:ok, 2} = ChangePollWorker.process_pull_requests(pulls)

      assert_enqueued(worker: Tracker.Nixpkgs.ChangeProcessWorker, args: %{"number" => 1001})
      assert_enqueued(worker: Tracker.Nixpkgs.ChangeProcessWorker, args: %{"number" => 1002})
    end

    test "skips PRs that are not merged" do
      pulls = [
        %{
          "number" => 2001,
          "state" => "closed",
          "merged_at" => nil,
          "title" => "closed without merge"
        },
        %{
          "number" => 2002,
          "state" => "open",
          "merged_at" => nil,
          "title" => "still open"
        }
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
        %{
          "number" => 3001,
          "state" => "closed",
          "merged_at" => "2026-04-01T12:00:00Z",
          "title" => "already tracked"
        },
        %{
          "number" => 3002,
          "state" => "closed",
          "merged_at" => "2026-04-01T13:00:00Z",
          "title" => "new one"
        }
      ]

      assert {:ok, 1} = ChangePollWorker.process_pull_requests(pulls)

      refute_enqueued(worker: Tracker.Nixpkgs.ChangeProcessWorker, args: %{"number" => 3001})
      assert_enqueued(worker: Tracker.Nixpkgs.ChangeProcessWorker, args: %{"number" => 3002})
    end
  end
end

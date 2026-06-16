defmodule Tracker.Nixpkgs.ChangeReconcileWorkerTest do
  use Tracker.DataCase, async: false

  import ExUnit.CaptureLog

  require Logger

  alias Tracker.GitHub.GraphQL.PullRequest
  alias Tracker.Nixpkgs.Change
  alias Tracker.Nixpkgs.ChangeReconcileSkip
  alias Tracker.Nixpkgs.ChangeReconcileWorker

  describe "reconcile_gaps/2" do
    test "returns ok with zero counts when there are no gaps" do
      for n <- 100..105, do: seed_change(n)

      fetcher = fn _numbers -> raise "should not be called" end

      assert {:ok, summary} = ChangeReconcileWorker.reconcile_gaps(fetcher, floor: 100)

      assert summary.checked == 0
      assert summary.prs_recovered == 0
      assert summary.skipped == 0
      assert summary.gaps_found == 0
    end

    test "upserts a PR when a gap resolves to a PullRequest" do
      seed_change(200)
      seed_change(202)

      fetcher = fn [201] ->
        {:ok, %{201 => {:pull_request, pr_struct(number: 201, state: :open)}}}
      end

      assert {:ok, summary} = ChangeReconcileWorker.reconcile_gaps(fetcher, floor: 200)
      assert summary.prs_recovered == 1
      assert summary.skipped == 0
      assert summary.gaps_found == 1

      assert {:ok, %Change{state: :open}} = Change.get_by_number(201)

      assert_enqueued(
        worker: Tracker.Nixpkgs.ChangeArtifactRefreshWorker,
        args: %{"number" => 201, "reason" => "head_sha_changed"}
      )
    end

    test "records issue gap in skips table and does not upsert a Change" do
      seed_change(300)
      seed_change(302)

      fetcher = fn [301] -> {:ok, %{301 => :issue}} end

      assert {:ok, summary} = ChangeReconcileWorker.reconcile_gaps(fetcher, floor: 300)
      assert summary.prs_recovered == 0
      assert summary.skipped == 1

      assert {:error, _} = Change.get_by_number(301)
      assert [%ChangeReconcileSkip{kind: :issue}] = ChangeReconcileSkip.read!()
    end

    test "records not_found (deleted/transferred) gap as a skip" do
      seed_change(400)
      seed_change(402)

      fetcher = fn [401] -> {:ok, %{401 => :not_found}} end

      assert {:ok, summary} = ChangeReconcileWorker.reconcile_gaps(fetcher, floor: 400)
      assert summary.skipped == 1
      assert [%ChangeReconcileSkip{number: 401, kind: :not_found}] = ChangeReconcileSkip.read!()
    end

    test "skips short-circuit subsequent runs (already-known non-PR numbers are not re-resolved)" do
      seed_change(500)
      seed_change(502)
      ChangeReconcileSkip.record!([%{number: 501, kind: :issue}])

      fetcher = fn _numbers -> raise "should not be called when only skip-covered gaps exist" end

      assert {:ok, summary} = ChangeReconcileWorker.reconcile_gaps(fetcher, floor: 500)
      assert summary.gaps_found == 0
      assert summary.checked == 0
    end

    test "lower-bound floor is respected: gaps below the floor are not investigated" do
      seed_change(600)
      seed_change(700)

      fetcher = fn numbers ->
        assert Enum.all?(numbers, &(&1 >= 650))
        {:ok, Map.new(numbers, &{&1, :not_found})}
      end

      assert {:ok, summary} = ChangeReconcileWorker.reconcile_gaps(fetcher, floor: 650)
      assert summary.gaps_found == 50
    end

    test "defaults the floor to MAX(number) - 5000 when no floor is configured" do
      seed_change(10_000)
      seed_change(10_001)

      {:ok, agent} = Agent.start_link(fn -> [] end)

      fetcher = fn numbers ->
        Agent.update(agent, &(numbers ++ &1))
        {:ok, Map.new(numbers, &{&1, :not_found})}
      end

      {:ok, summary} = ChangeReconcileWorker.reconcile_gaps(fetcher, batch_size: 100)
      assert summary.gaps_found == 100

      seen = Agent.get(agent, & &1)
      # Walked DESC from MAX-1 = 9_999, took the top 100. Implicit floor of
      # 10_001 - 5_000 = 5_001 is comfortably below 9_900.
      assert Enum.max(seen) == 9_999
      assert Enum.min(seen) == 9_900
    end

    test "returns :ok with zero counts when DB has no Changes" do
      fetcher = fn _ -> raise "should not be called" end
      assert {:ok, summary} = ChangeReconcileWorker.reconcile_gaps(fetcher, [])
      assert summary.gaps_found == 0
    end

    test "propagates a fetch error" do
      seed_change(800)
      seed_change(802)

      error = %GitHub.Error{
        reason: :rate_limited,
        message: "rate limited",
        code: 403,
        source: nil,
        step: nil
      }

      fetcher = fn _ -> {:error, error} end

      assert {:error, %GitHub.Error{reason: :rate_limited}} =
               ChangeReconcileWorker.reconcile_gaps(fetcher, floor: 800)
    end

    test "investigates gaps in DESC order, capped by batch_size" do
      seed_change(900)
      seed_change(910)

      fetcher = fn numbers ->
        # batch_size = 3, gaps in DESC order: 909, 908, 907
        assert numbers == [909, 908, 907]
        {:ok, Map.new(numbers, &{&1, :not_found})}
      end

      {:ok, summary} = ChangeReconcileWorker.reconcile_gaps(fetcher, floor: 900, batch_size: 3)
      assert summary.gaps_found == 3
    end

    test "emits structured start/stop logs with summary fields" do
      seed_change(1000)
      seed_change(1002)

      fetcher = fn [1001] ->
        {:ok, %{1001 => {:pull_request, pr_struct(number: 1001, state: :open)}}}
      end

      Logger.put_module_level(ChangeReconcileWorker, :info)
      on_exit(fn -> Logger.delete_module_level(ChangeReconcileWorker) end)

      log =
        capture_log(fn ->
          assert {:ok, _} = ChangeReconcileWorker.reconcile_gaps(fetcher, floor: 1000)
        end)

      assert log =~ ~s(msg: "change reconcile started")
      assert log =~ "max_number: 1002"
      assert log =~ "floor: 1000"
      assert log =~ ~s(msg: "change reconcile finished")
      assert log =~ "outcome: :ok"
      assert log =~ "gaps_found: 1"
      assert log =~ "checked: 1"
      assert log =~ "prs_recovered: 1"
      assert log =~ "skipped: 0"
      assert log =~ ~r/duration_ms: \d+/
    end
  end

  defp seed_change(number) do
    Change.bulk_upsert_all([
      %{
        number: number,
        title: "seed PR #{number}",
        state: :open,
        author: "tester",
        url: "https://github.com/NixOS/nixpkgs/pull/#{number}",
        base_ref: "master",
        head_sha: "seedsha#{number}"
      }
    ])
  end

  defp pr_struct(overrides) do
    overrides = Map.new(overrides)
    number = Map.get(overrides, :number, 1)

    defaults = %{
      node_id: "PR_node_#{number}",
      number: number,
      title: "test PR",
      state: :open,
      base_ref: "master",
      head_ref: "feature",
      head_sha: "headsha#{number}",
      url: "https://github.com/NixOS/nixpkgs/pull/#{number}",
      author: "testuser",
      author_github_id: 1,
      merged_by_github_id: nil,
      created_at: ~U[2026-04-01 12:00:00Z],
      updated_at: ~U[2026-04-01 12:00:00Z],
      closed_at: nil,
      merged_at: nil,
      merge_commit_sha: nil,
      labels: []
    }

    struct!(PullRequest, Map.merge(defaults, overrides))
  end
end

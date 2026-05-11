defmodule Tracker.Nixpkgs.ChangeDiscoveryWorkerTest do
  use Tracker.DataCase, async: true

  alias Tracker.GitHub.GraphQL.PullRequest
  alias Tracker.Nixpkgs.Change
  alias Tracker.Nixpkgs.ChangeBranch
  alias Tracker.Nixpkgs.ChangeDiscoveryWorker

  describe "discover_pages/2" do
    test "upserts every PR on every fetched page and enqueues head_sha_changed for new open/draft" do
      fetcher = fn _since, nil ->
        {:ok,
         %{
           pulls: [
             pr_struct(number: 5001, state: :open),
             pr_struct(number: 5002, state: :draft)
           ],
           next_cursor: nil,
           issue_count: 2
         }}
      end

      since = ~U[2026-01-01 00:00:00Z]

      assert {:ok, 2} = ChangeDiscoveryWorker.discover_pages(fetcher, since)

      assert {:ok, %Change{state: :open}} = Change.get_by_number(5001)
      assert {:ok, %Change{state: :draft}} = Change.get_by_number(5002)

      assert_enqueued(
        worker: Tracker.Nixpkgs.ChangeArtifactRefreshWorker,
        args: %{"number" => 5001, "reason" => "head_sha_changed"}
      )

      assert_enqueued(
        worker: Tracker.Nixpkgs.ChangeArtifactRefreshWorker,
        args: %{"number" => 5002, "reason" => "head_sha_changed"}
      )
    end

    test "does not enqueue artifact work for already-existing open Changes" do
      Change.bulk_upsert_all([
        %{
          number: 5050,
          title: "pre-existing",
          state: :open,
          author: "tester",
          url: "https://github.com/NixOS/nixpkgs/pull/5050",
          base_ref: "master",
          head_sha: "headsha1"
        }
      ])

      fetcher = fn _since, nil ->
        {:ok, %{pulls: [pr_struct(number: 5050, state: :open)], next_cursor: nil, issue_count: 1}}
      end

      assert {:ok, 1} = ChangeDiscoveryWorker.discover_pages(fetcher, ~U[2026-01-01 00:00:00Z])
      refute_enqueued(worker: Tracker.Nixpkgs.ChangeArtifactRefreshWorker)
    end

    test "does not enqueue artifact work for newly-discovered closed (non-merged) PRs" do
      fetcher = fn _since, nil ->
        {:ok,
         %{pulls: [pr_struct(number: 5099, state: :closed)], next_cursor: nil, issue_count: 1}}
      end

      assert {:ok, 1} = ChangeDiscoveryWorker.discover_pages(fetcher, ~U[2026-01-01 00:00:00Z])
      assert {:ok, %Change{state: :closed}} = Change.get_by_number(5099)
      refute_enqueued(worker: Tracker.Nixpkgs.ChangeArtifactRefreshWorker)
    end

    test "drains all pages within a single since-window" do
      fetcher = fn
        _since, nil ->
          {:ok,
           %{
             pulls: [pr_struct(number: 7001, updated_at: ~U[2026-04-10 00:00:00Z])],
             next_cursor: "CURSOR_2",
             issue_count: 2
           }}

        _since, "CURSOR_2" ->
          {:ok,
           %{
             pulls: [pr_struct(number: 7002, updated_at: ~U[2026-04-20 00:00:00Z])],
             next_cursor: nil,
             issue_count: 2
           }}
      end

      assert {:ok, 2} =
               ChangeDiscoveryWorker.discover_pages(fetcher, ~U[2026-04-01 00:00:00Z])

      assert {:ok, %Change{}} = Change.get_by_number(7001)
      assert {:ok, %Change{}} = Change.get_by_number(7002)
    end

    test "stops on empty page" do
      fetcher = fn _since, nil ->
        {:ok, %{pulls: [], next_cursor: nil, issue_count: 0}}
      end

      assert {:ok, 0} = ChangeDiscoveryWorker.discover_pages(fetcher, ~U[2026-01-01 00:00:00Z])
    end

    test "re-queries with advanced since when issue_count exceeds the search cap" do
      initial_since = ~U[2026-04-01 00:00:00Z]
      capped_last = ~U[2026-04-05 12:00:00Z]

      {:ok, agent} = Agent.start_link(fn -> [] end)

      fetcher = fn since, cursor ->
        Agent.update(agent, &[{since, cursor} | &1])

        case {since, cursor} do
          {^initial_since, nil} ->
            {:ok,
             %{
               pulls: [
                 pr_struct(number: 7501, updated_at: ~U[2026-04-02 00:00:00Z]),
                 pr_struct(number: 7502, updated_at: capped_last)
               ],
               next_cursor: nil,
               issue_count: 1500
             }}

          {^capped_last, nil} ->
            {:ok,
             %{
               pulls: [pr_struct(number: 7503, updated_at: ~U[2026-04-06 00:00:00Z])],
               next_cursor: nil,
               issue_count: 1
             }}
        end
      end

      assert {:ok, 3} = ChangeDiscoveryWorker.discover_pages(fetcher, initial_since)

      calls = Agent.get(agent, & &1) |> Enum.reverse()
      assert calls == [{initial_since, nil}, {capped_last, nil}]

      assert {:ok, %Change{}} = Change.get_by_number(7501)
      assert {:ok, %Change{}} = Change.get_by_number(7502)
      assert {:ok, %Change{}} = Change.get_by_number(7503)
    end

    test "does not re-query when issue_count is within the cap" do
      fetcher = fn
        _since, nil ->
          {:ok,
           %{
             pulls: [pr_struct(number: 7600, updated_at: ~U[2026-04-05 00:00:00Z])],
             next_cursor: nil,
             issue_count: 1
           }}

        _since, _cursor ->
          raise "should not re-query"
      end

      assert {:ok, 1} =
               ChangeDiscoveryWorker.discover_pages(fetcher, ~U[2026-04-01 00:00:00Z])
    end

    test "does not enqueue artifact work for merged PRs" do
      fetcher = fn _since, nil ->
        {:ok,
         %{
           pulls: [
             pr_struct(
               number: 8001,
               state: :merged,
               merged_at: ~U[2026-04-01 00:00:00Z],
               merge_commit_sha: "deadbeef"
             )
           ],
           next_cursor: nil,
           issue_count: 1
         }}
      end

      assert {:ok, 1} = ChangeDiscoveryWorker.discover_pages(fetcher, ~U[2026-01-01 00:00:00Z])
      assert {:ok, %Change{state: :merged}} = Change.get_by_number(8001)
      refute_enqueued(worker: Tracker.Nixpkgs.ChangeArtifactRefreshWorker)
    end

    test "seeds base_ref ChangeBranch for newly-merged PRs" do
      fetcher = fn _since, nil ->
        {:ok,
         %{
           pulls: [
             pr_struct(
               number: 8200,
               state: :merged,
               base_ref: "master",
               merged_at: ~U[2026-04-01 00:00:00Z],
               merge_commit_sha: "deadbeef"
             )
           ],
           next_cursor: nil,
           issue_count: 1
         }}
      end

      assert {:ok, 1} = ChangeDiscoveryWorker.discover_pages(fetcher, ~U[2026-01-01 00:00:00Z])
      assert {:ok, %Change{id: change_id, state: :merged}} = Change.get_by_number(8200)

      branches = ChangeBranch.read!() |> Enum.filter(&(&1.change_id == change_id))
      assert [%ChangeBranch{branch_name: "master"}] = branches
    end

    test "ignores non-propagation base_ref when seeding ChangeBranch" do
      fetcher = fn _since, nil ->
        {:ok,
         %{
           pulls: [
             pr_struct(
               number: 8201,
               state: :merged,
               base_ref: "topic/random-branch",
               merged_at: ~U[2026-04-01 00:00:00Z],
               merge_commit_sha: "deadbeef"
             )
           ],
           next_cursor: nil,
           issue_count: 1
         }}
      end

      assert {:ok, 1} = ChangeDiscoveryWorker.discover_pages(fetcher, ~U[2026-01-01 00:00:00Z])
      assert {:ok, %Change{id: change_id}} = Change.get_by_number(8201)

      branches = ChangeBranch.read!() |> Enum.filter(&(&1.change_id == change_id))
      assert branches == []
    end

    test "propagates rate limit error" do
      error = %GitHub.Error{
        reason: :rate_limited,
        message: "API rate limit exceeded",
        code: 403,
        operation: nil,
        source: nil,
        stacktrace: [],
        step: nil
      }

      fetcher = fn _since, nil -> {:error, error} end

      assert {:error, %GitHub.Error{reason: :rate_limited}} =
               ChangeDiscoveryWorker.discover_pages(fetcher, ~U[2026-01-01 00:00:00Z])
    end

    test "propagates generic fetch error" do
      error = %GitHub.Error{
        reason: :server_error,
        message: "Internal Server Error",
        code: 500,
        operation: nil,
        source: nil,
        stacktrace: [],
        step: nil
      }

      fetcher = fn _since, nil -> {:error, error} end

      assert {:error, %GitHub.Error{reason: :server_error}} =
               ChangeDiscoveryWorker.discover_pages(fetcher, ~U[2026-01-01 00:00:00Z])
    end
  end

  describe "checkpoint/0" do
    test "returns max gh_updated_at minus 60s overlap when newer than the 90-day floor" do
      Change.bulk_upsert_all([
        %{
          number: 9101,
          title: "older",
          state: :open,
          gh_updated_at: ~U[2026-04-10 00:00:00Z]
        },
        %{
          number: 9102,
          title: "newer",
          state: :open,
          gh_updated_at: ~U[2026-04-20 00:00:00Z]
        }
      ])

      assert ChangeDiscoveryWorker.checkpoint() == ~U[2026-04-19 23:59:00Z]
    end

    test "returns the 90-day floor when the DB is empty" do
      floor = DateTime.utc_now() |> DateTime.add(-90, :day)
      got = ChangeDiscoveryWorker.checkpoint()

      assert DateTime.diff(got, floor) |> abs() < 5
    end
  end

  describe "parse_pr_payload/1" do
    test "passes through state from the GraphQL struct" do
      assert %{state: :merged} =
               ChangeDiscoveryWorker.parse_pr_payload(pr_struct(state: :merged))

      assert %{state: :closed} =
               ChangeDiscoveryWorker.parse_pr_payload(pr_struct(state: :closed))

      assert %{state: :draft} =
               ChangeDiscoveryWorker.parse_pr_payload(pr_struct(state: :draft))

      assert %{state: :open} =
               ChangeDiscoveryWorker.parse_pr_payload(pr_struct(state: :open))
    end

    test "drops merge_commit_sha for non-merged PRs (test-merge SHA leaks)" do
      for state <- [:open, :draft, :closed] do
        pr = pr_struct(state: state, merge_commit_sha: "testmergesha")
        assert %{merge_commit_sha: nil} = ChangeDiscoveryWorker.parse_pr_payload(pr)
      end
    end

    test "keeps merge_commit_sha for merged PRs" do
      pr =
        pr_struct(
          state: :merged,
          merged_at: ~U[2026-04-01 00:00:00Z],
          merge_commit_sha: "realmergesha"
        )

      assert %{merge_commit_sha: "realmergesha"} = ChangeDiscoveryWorker.parse_pr_payload(pr)
    end

    test "extracts the full attribute set including merged_by/author/url" do
      pr =
        pr_struct(
          number: 9001,
          node_id: "PR_node_9001",
          title: "fix something",
          state: :open,
          updated_at: ~U[2026-04-15 09:00:00Z],
          created_at: ~U[2026-04-14 08:00:00Z],
          url: "https://github.com/NixOS/nixpkgs/pull/9001",
          author: "octocat",
          author_github_id: 583_231,
          merged_by_github_id: nil,
          labels: ["bug", "10.rebuild-linux: 1"]
        )

      assert %{
               number: 9001,
               node_id: "PR_node_9001",
               title: "fix something",
               state: :open,
               url: "https://github.com/NixOS/nixpkgs/pull/9001",
               author: "octocat",
               author_github_id: 583_231,
               merged_by_github_id: nil,
               labels: ["bug", "10.rebuild-linux: 1"],
               gh_created_at: ~U[2026-04-14 08:00:00Z],
               gh_updated_at: ~U[2026-04-15 09:00:00Z],
               base_ref: "master",
               head_ref: "feature",
               head_sha: "headsha1"
             } = ChangeDiscoveryWorker.parse_pr_payload(pr)
    end

    test "populates merged_by_github_id when present" do
      pr =
        pr_struct(
          state: :merged,
          merged_at: ~U[2026-04-01 00:00:00Z],
          merge_commit_sha: "realmergesha",
          merged_by_github_id: 100_500
        )

      assert %{merged_by_github_id: 100_500} = ChangeDiscoveryWorker.parse_pr_payload(pr)
    end
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
      head_sha: "headsha1",
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

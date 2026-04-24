defmodule Tracker.Nixpkgs.ChangeDiscoveryWorkerTest do
  use Tracker.DataCase, async: true

  alias Tracker.Nixpkgs.Change
  alias Tracker.Nixpkgs.ChangeDiscoveryWorker

  describe "discover_pages/2" do
    test "upserts every PR on every fetched page" do
      fetcher = fn
        1 ->
          {:ok,
           [
             pr_struct(number: 5001, state: "open", merged_at: nil),
             pr_struct(number: 5002, state: "open", draft: true, merged_at: nil)
           ]}

        2 ->
          {:ok, []}
      end

      watermark = ~U[2026-01-01 00:00:00Z]

      assert {:ok, 2} = ChangeDiscoveryWorker.discover_pages(fetcher, watermark)

      assert {:ok, %Change{state: :open}} = Change.get_by_number(5001)
      assert {:ok, %Change{state: :draft}} = Change.get_by_number(5002)
      refute_enqueued(worker: Tracker.Nixpkgs.ChangeProcessWorker)
    end

    test "stops paging when last PR on page is older than watermark" do
      watermark = ~U[2026-04-15 00:00:00Z]

      fetcher = fn
        1 ->
          {:ok,
           [
             pr_struct(number: 6001, updated_at: ~U[2026-04-20 00:00:00Z]),
             pr_struct(number: 6002, updated_at: ~U[2026-04-10 00:00:00Z])
           ]}

        2 ->
          raise "should not fetch page 2"
      end

      assert {:ok, 2} = ChangeDiscoveryWorker.discover_pages(fetcher, watermark)
      assert {:ok, %Change{}} = Change.get_by_number(6001)
      assert {:ok, %Change{}} = Change.get_by_number(6002)
    end

    test "continues paging while last PR on page is newer than watermark" do
      watermark = ~U[2026-04-01 00:00:00Z]

      fetcher = fn
        1 -> {:ok, [pr_struct(number: 7001, updated_at: ~U[2026-04-20 00:00:00Z])]}
        2 -> {:ok, [pr_struct(number: 7002, updated_at: ~U[2026-04-10 00:00:00Z])]}
        3 -> {:ok, []}
      end

      assert {:ok, 2} = ChangeDiscoveryWorker.discover_pages(fetcher, watermark)
      assert {:ok, %Change{}} = Change.get_by_number(7001)
      assert {:ok, %Change{}} = Change.get_by_number(7002)
    end

    test "stops on empty page" do
      watermark = ~U[2026-01-01 00:00:00Z]

      fetcher = fn
        1 -> {:ok, []}
        2 -> raise "should not fetch page 2"
      end

      assert {:ok, 0} = ChangeDiscoveryWorker.discover_pages(fetcher, watermark)
    end

    test "does not enqueue ChangeProcessWorker for merged PRs" do
      watermark = ~U[2026-01-01 00:00:00Z]

      fetcher = fn
        1 ->
          {:ok,
           [
             pr_struct(
               number: 8001,
               state: "closed",
               merged_at: ~U[2026-04-01 00:00:00Z],
               merge_commit_sha: "deadbeef"
             )
           ]}

        2 ->
          {:ok, []}
      end

      assert {:ok, 1} = ChangeDiscoveryWorker.discover_pages(fetcher, watermark)
      assert {:ok, %Change{state: :merged}} = Change.get_by_number(8001)
      refute_enqueued(worker: Tracker.Nixpkgs.ChangeProcessWorker)
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

      fetcher = fn 1 -> {:error, error} end

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

      fetcher = fn 1 -> {:error, error} end

      assert {:error, %GitHub.Error{reason: :server_error}} =
               ChangeDiscoveryWorker.discover_pages(fetcher, ~U[2026-01-01 00:00:00Z])
    end
  end

  describe "parse_pr_payload/1" do
    test "maps merged_at to :merged state" do
      pr = pr_struct(number: 1, state: "closed", merged_at: ~U[2026-04-01 00:00:00Z])
      assert %{state: :merged} = ChangeDiscoveryWorker.parse_pr_payload(pr)
    end

    test "maps state=closed without merged_at to :closed" do
      pr = pr_struct(number: 1, state: "closed", merged_at: nil)
      assert %{state: :closed} = ChangeDiscoveryWorker.parse_pr_payload(pr)
    end

    test "maps state=open + draft=true to :draft" do
      pr = pr_struct(number: 1, state: "open", draft: true, merged_at: nil)
      assert %{state: :draft} = ChangeDiscoveryWorker.parse_pr_payload(pr)
    end

    test "maps state=open + draft=false to :open" do
      pr = pr_struct(number: 1, state: "open", draft: false, merged_at: nil)
      assert %{state: :open} = ChangeDiscoveryWorker.parse_pr_payload(pr)
    end

    test "handles the list endpoint shape (no :merged_by key)" do
      # GitHub.Pulls.list returns a map shaped like GitHub.PullRequest.simple()
      # which omits :merged_by entirely. Guard against KeyError on missing key.
      pr =
        pr_struct(number: 1)
        |> Map.from_struct()
        |> Map.delete(:merged_by)

      refute Map.has_key?(pr, :merged_by)

      assert %{merged_by_github_id: nil} = ChangeDiscoveryWorker.parse_pr_payload(pr)
    end

    test "extracts full attribute set" do
      pr =
        pr_struct(
          number: 9001,
          node_id: "PR_node_9001",
          title: "fix something",
          state: "open",
          draft: false,
          merged_at: nil,
          updated_at: ~U[2026-04-15 09:00:00Z],
          created_at: ~U[2026-04-14 08:00:00Z],
          closed_at: nil,
          html_url: "https://github.com/NixOS/nixpkgs/pull/9001",
          labels: [%GitHub.Label{name: "bug"}, %GitHub.Label{name: "10.rebuild-linux: 1"}]
        )

      assert %{
               number: 9001,
               node_id: "PR_node_9001",
               title: "fix something",
               state: :open,
               url: "https://github.com/NixOS/nixpkgs/pull/9001",
               labels: ["bug", "10.rebuild-linux: 1"],
               gh_created_at: ~U[2026-04-14 08:00:00Z],
               gh_updated_at: ~U[2026-04-15 09:00:00Z],
               base_ref: "master",
               head_ref: "feature",
               head_sha: "headsha1"
             } = ChangeDiscoveryWorker.parse_pr_payload(pr)
    end
  end

  defp pr_struct(overrides) do
    defaults = [
      number: 1,
      node_id: "PR_node_#{Keyword.get(overrides, :number, 1)}",
      title: "test PR",
      state: "open",
      draft: false,
      merged_at: nil,
      merge_commit_sha: nil,
      closed_at: nil,
      created_at: ~U[2026-04-01 12:00:00Z],
      updated_at: ~U[2026-04-01 12:00:00Z],
      html_url: "https://github.com/NixOS/nixpkgs/pull/1",
      user: %GitHub.User{login: "testuser", id: 1},
      base: %GitHub.PullRequest.Base{ref: "master"},
      head: %GitHub.PullRequest.Head{ref: "feature", sha: "headsha1"},
      labels: []
    ]

    struct!(GitHub.PullRequest, Keyword.merge(defaults, overrides))
  end
end

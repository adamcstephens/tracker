defmodule Tracker.Nixpkgs.ChangeRefreshWorkerTest do
  use Tracker.DataCase, async: false

  import ExUnit.CaptureLog

  alias Tracker.GitHub.GraphQL.PullRequest
  alias Tracker.GitHub.RateLimitCache
  alias Tracker.Nixpkgs.Change
  alias Tracker.Nixpkgs.ChangeBranch
  alias Tracker.Nixpkgs.ChangePackage
  alias Tracker.Nixpkgs.ChangeRefreshWorker
  alias Tracker.Nixpkgs.Package

  setup do
    table = :"rate_limit_cache_refresh_#{System.unique_integer([:positive])}"
    RateLimitCache.new(table)
    on_exit(fn -> if :ets.whereis(table) != :undefined, do: :ets.delete(table) end)
    %{rate_limit_table: table}
  end

  describe "run/1" do
    test "returns :noop when no unfinished changes exist" do
      fetcher = fn _ids -> raise "should not call fetcher" end

      assert {:ok, 0} = ChangeRefreshWorker.run(fetcher: fetcher)
    end

    test "fetches only non-terminal changes with a node_id, oldest last_checked_at first" do
      insert_change!(number: 1, state: :open, node_id: "pr_old", last_checked_at: hours_ago(10))
      insert_change!(number: 2, state: :open, node_id: "pr_newer", last_checked_at: hours_ago(1))
      insert_change!(number: 3, state: :merged, node_id: "pr_merged")
      insert_change!(number: 4, state: :closed, node_id: "pr_closed")
      insert_change!(number: 5, state: :open, node_id: nil)

      captured_ids =
        fetcher_returning(fn ids ->
          for id <- ids, into: %{}, do: {id, pr(node_id: id, number: number_of(id))}
        end)

      {:ok, count} = ChangeRefreshWorker.run(fetcher: captured_ids.fn)
      assert count == 2

      [ids] = captured_ids.calls.()
      # oldest first
      assert ids == ["pr_old", "pr_newer"]
    end

    test "open → merged transition updates state and emits :merged transition" do
      insert_change!(number: 100, state: :open, node_id: "pr_m", head_sha: "sha_old")
      recorder = transition_recorder()

      ChangeRefreshWorker.run(
        fetcher: fn _ ->
          {:ok,
           %{
             "pr_m" =>
               pr(
                 node_id: "pr_m",
                 number: 100,
                 state: :merged,
                 head_sha: "sha_old",
                 merged_at: ~U[2026-04-23 10:00:00Z],
                 merge_commit_sha: "mcsha"
               )
           }}
        end,
        on_transition: recorder.fn
      )

      assert {:ok,
              %Change{state: :merged, merge_commit_sha: "mcsha", last_checked_at: %DateTime{}}} =
               Change.get_by_number(100)

      assert [{%Change{number: 100}, :merged}] = recorder.calls.()
    end

    test "head_sha change on open PR emits :head_sha_changed transition" do
      insert_change!(number: 101, state: :open, node_id: "pr_hs", head_sha: "old_sha")
      recorder = transition_recorder()

      ChangeRefreshWorker.run(
        fetcher: fn _ ->
          {:ok,
           %{
             "pr_hs" =>
               pr(
                 node_id: "pr_hs",
                 number: 101,
                 state: :open,
                 head_sha: "new_sha"
               )
           }}
        end,
        on_transition: recorder.fn
      )

      assert {:ok, %Change{state: :open, head_sha: "new_sha"}} = Change.get_by_number(101)
      assert [{%Change{number: 101}, :head_sha_changed}] = recorder.calls.()
    end

    test "draft → open transition (same head_sha) does not emit any transition" do
      insert_change!(number: 102, state: :draft, node_id: "pr_do", head_sha: "samesha")
      recorder = transition_recorder()

      ChangeRefreshWorker.run(
        fetcher: fn _ ->
          {:ok,
           %{
             "pr_do" => pr(node_id: "pr_do", number: 102, state: :open, head_sha: "samesha")
           }}
        end,
        on_transition: recorder.fn
      )

      assert {:ok, %Change{state: :open}} = Change.get_by_number(102)
      assert recorder.calls.() == []
    end

    test "open → closed (no merge) emits :closed_no_merge transition" do
      insert_change!(number: 103, state: :open, node_id: "pr_cl", head_sha: "sha_cl")
      recorder = transition_recorder()

      ChangeRefreshWorker.run(
        fetcher: fn _ ->
          {:ok,
           %{
             "pr_cl" =>
               pr(
                 node_id: "pr_cl",
                 number: 103,
                 state: :closed,
                 head_sha: "sha_cl",
                 closed_at: ~U[2026-04-23 09:00:00Z]
               )
           }}
        end,
        on_transition: recorder.fn
      )

      assert {:ok, %Change{state: :closed, closed_at: %DateTime{}}} = Change.get_by_number(103)
      assert [{%Change{number: 103}, :closed_no_merge}] = recorder.calls.()
    end

    test "draft → closed (no merge) emits :closed_no_merge transition" do
      insert_change!(number: 109, state: :draft, node_id: "pr_dcl", head_sha: "sha_dcl")
      recorder = transition_recorder()

      ChangeRefreshWorker.run(
        fetcher: fn _ ->
          {:ok,
           %{
             "pr_dcl" =>
               pr(
                 node_id: "pr_dcl",
                 number: 109,
                 state: :closed,
                 head_sha: "sha_dcl",
                 closed_at: ~U[2026-04-23 09:00:00Z]
               )
           }}
        end,
        on_transition: recorder.fn
      )

      assert [{%Change{number: 109}, :closed_no_merge}] = recorder.calls.()
    end

    test ":not_found bumps last_checked_at, keeps state, and warns" do
      insert_change!(number: 104, state: :open, node_id: "pr_gone", last_checked_at: nil)

      log =
        capture_log(fn ->
          ChangeRefreshWorker.run(fetcher: fn _ -> {:ok, %{"pr_gone" => :not_found}} end)
        end)

      assert {:ok, %Change{state: :open, last_checked_at: %DateTime{}}} =
               Change.get_by_number(104)

      assert log =~ "not_found"
      assert log =~ "pr_gone"
    end

    test "last_checked_at is bumped even when nothing else changes" do
      old_time = DateTime.add(DateTime.utc_now(), -3600, :second)

      insert_change!(
        number: 105,
        state: :open,
        node_id: "pr_same",
        head_sha: "unchanged_sha",
        title: "same title",
        last_checked_at: old_time
      )

      ChangeRefreshWorker.run(
        fetcher: fn _ ->
          {:ok,
           %{
             "pr_same" =>
               pr(
                 node_id: "pr_same",
                 number: 105,
                 state: :open,
                 head_sha: "unchanged_sha",
                 title: "same title"
               )
           }}
        end
      )

      {:ok, change} = Change.get_by_number(105)
      assert DateTime.after?(change.last_checked_at, old_time)
    end

    test "base_ref change persists from GraphQL response" do
      insert_change!(
        number: 110,
        state: :open,
        node_id: "pr_br",
        head_sha: "sha_br",
        base_ref: "master"
      )

      ChangeRefreshWorker.run(
        fetcher: fn _ ->
          {:ok,
           %{
             "pr_br" =>
               pr(
                 node_id: "pr_br",
                 number: 110,
                 state: :open,
                 head_sha: "sha_br",
                 base_ref: "staging-next",
                 head_ref: "topic/retarget"
               )
           }}
        end
      )

      assert {:ok, %Change{base_ref: "staging-next", head_ref: "topic/retarget"}} =
               Change.get_by_number(110)
    end

    test "labels and title update from GraphQL response" do
      insert_change!(number: 106, state: :open, node_id: "pr_lbl", labels: ["old"])

      ChangeRefreshWorker.run(
        fetcher: fn _ ->
          {:ok,
           %{
             "pr_lbl" =>
               pr(
                 node_id: "pr_lbl",
                 number: 106,
                 state: :open,
                 title: "new title",
                 labels: ["bug", "priority"]
               )
           }}
        end
      )

      assert {:ok, %Change{title: "new title", labels: ["bug", "priority"]}} =
               Change.get_by_number(106)
    end

    test "rate-limited error snoozes" do
      insert_change!(number: 107, state: :open, node_id: "pr_rl")

      error = %GitHub.Error{reason: :rate_limited, code: 403}

      assert {:snooze, 42} =
               ChangeRefreshWorker.run(
                 fetcher: fn _ -> {:error, error} end,
                 snoozer: fn -> 42 end
               )
    end

    test "propagates generic errors" do
      insert_change!(number: 108, state: :open, node_id: "pr_err")
      error = %GitHub.Error{reason: :server_error, code: 500}

      assert {:error, %GitHub.Error{reason: :server_error}} =
               ChangeRefreshWorker.run(fetcher: fn _ -> {:error, error} end)
    end

    test "emits structured start/stop logs with transition counts" do
      insert_change!(number: 200, state: :open, node_id: "pr_x", head_sha: "old")
      recorder = transition_recorder()
      require Logger
      Logger.put_module_level(ChangeRefreshWorker, :info)
      on_exit(fn -> Logger.delete_module_level(ChangeRefreshWorker) end)

      log =
        capture_log(fn ->
          ChangeRefreshWorker.run(
            fetcher: fn _ ->
              {:ok,
               %{
                 "pr_x" =>
                   pr(
                     node_id: "pr_x",
                     number: 200,
                     state: :merged,
                     head_sha: "old",
                     merged_at: ~U[2026-04-23 10:00:00Z],
                     merge_commit_sha: "mc"
                   )
               }}
            end,
            on_transition: recorder.fn
          )
        end)

      assert log =~ ~s(msg: "change refresh started")
      assert log =~ ~s(msg: "change refresh finished")
      assert log =~ "outcome: :ok"
      assert log =~ "checked: 1"
      assert log =~ "merged: 1"
      assert log =~ "head_sha_changed: 0"
      assert log =~ "not_found: 0"
      assert log =~ ~r/duration_ms: \d+/
    end
  end

  describe "default on_transition hook" do
    test "enqueues ChangeArtifactRefreshWorker for :merged transitions" do
      insert_change!(number: 300, state: :open, node_id: "pr_def_m", head_sha: "sha_old")

      ChangeRefreshWorker.run(
        fetcher: fn _ ->
          {:ok,
           %{
             "pr_def_m" =>
               pr(
                 node_id: "pr_def_m",
                 number: 300,
                 state: :merged,
                 head_sha: "sha_old",
                 merged_at: ~U[2026-04-23 10:00:00Z],
                 merge_commit_sha: "mcsha"
               )
           }}
        end
      )

      assert_enqueued(
        worker: Tracker.Nixpkgs.ChangeArtifactRefreshWorker,
        args: %{"number" => 300, "reason" => "merged"}
      )
    end

    test "seeds base_ref ChangeBranch on :merged transition" do
      insert_change!(
        number: 310,
        state: :open,
        node_id: "pr_def_seed",
        head_sha: "sha_seed",
        base_ref: "master"
      )

      ChangeRefreshWorker.run(
        fetcher: fn _ ->
          {:ok,
           %{
             "pr_def_seed" =>
               pr(
                 node_id: "pr_def_seed",
                 number: 310,
                 state: :merged,
                 base_ref: "master",
                 head_sha: "sha_seed",
                 merged_at: ~U[2026-04-23 10:00:00Z],
                 merge_commit_sha: "mcsha_seed"
               )
           }}
        end
      )

      {:ok, change} = Change.get_by_number(310)
      change = Ash.load!(change, :change_branches)
      assert [%ChangeBranch{branch_name: "master"}] = change.change_branches
    end

    test "skips base_ref seed when base_ref is not in propagation graph" do
      insert_change!(
        number: 311,
        state: :open,
        node_id: "pr_def_skip",
        head_sha: "sha_skip",
        base_ref: "some-feature-branch"
      )

      ChangeRefreshWorker.run(
        fetcher: fn _ ->
          {:ok,
           %{
             "pr_def_skip" =>
               pr(
                 node_id: "pr_def_skip",
                 number: 311,
                 state: :merged,
                 base_ref: "some-feature-branch",
                 head_sha: "sha_skip",
                 merged_at: ~U[2026-04-23 10:00:00Z],
                 merge_commit_sha: "mcsha_skip"
               )
           }}
        end
      )

      {:ok, change} = Change.get_by_number(311)
      change = Ash.load!(change, :change_branches)
      assert change.change_branches == []
    end

    test "enqueues ChangeArtifactRefreshWorker for :head_sha_changed transitions" do
      insert_change!(number: 301, state: :open, node_id: "pr_def_hs", head_sha: "sha_a")

      ChangeRefreshWorker.run(
        fetcher: fn _ ->
          {:ok,
           %{
             "pr_def_hs" => pr(node_id: "pr_def_hs", number: 301, state: :open, head_sha: "sha_b")
           }}
        end
      )

      assert_enqueued(
        worker: Tracker.Nixpkgs.ChangeArtifactRefreshWorker,
        args: %{"number" => 301, "reason" => "head_sha_changed"}
      )
    end

    test "clears ChangePackage links and resets package_count on :closed_no_merge" do
      insert_change!(
        number: 302,
        state: :open,
        node_id: "pr_def_cl",
        head_sha: "sha_cl",
        package_count: 3
      )

      {:ok, change} = Change.get_by_number(302)
      package = insert_package!("foo")

      ChangePackage.bulk_create_all([
        %{change_id: change.id, package_id: package.id, type: :added}
      ])

      ChangeRefreshWorker.run(
        fetcher: fn _ ->
          {:ok,
           %{
             "pr_def_cl" =>
               pr(
                 node_id: "pr_def_cl",
                 number: 302,
                 state: :closed,
                 head_sha: "sha_cl",
                 closed_at: ~U[2026-04-23 09:00:00Z]
               )
           }}
        end
      )

      assert {:ok, %Change{state: :closed, package_count: 0}} = Change.get_by_number(302)

      import Ecto.Query

      assert Tracker.Repo.one(
               from(cp in ChangePackage, where: cp.change_id == ^change.id, select: count(cp.id))
             ) == 0
    end
  end

  describe "rate-limit short-circuit" do
    test "skips when :graphql rate-limit cache says limited", %{rate_limit_table: table} do
      reset_at = System.os_time(:second) + 300
      RateLimitCache.set_reset(:graphql, reset_at, table)

      insert_change!(number: 200, state: :open, node_id: "pr_skip")

      fetcher = fn _ -> raise "should not call fetcher" end

      assert :ok =
               ChangeRefreshWorker.run(fetcher: fetcher, rate_limit_table: table)
    end
  end

  defp insert_change!(attrs) do
    defaults = %{
      title: "test PR ##{attrs[:number]}",
      state: :open,
      author: "tester",
      url: "https://github.com/NixOS/nixpkgs/pull/#{attrs[:number]}",
      base_ref: "master"
    }

    record =
      attrs
      |> Map.new()
      |> Map.merge(defaults, fn _k, v, _d -> v end)

    Change.bulk_upsert_all([record])
  end

  defp insert_package!(attribute) do
    Package.bulk_upsert_all([%{attribute: attribute}])

    require Ash.Query

    Package
    |> Ash.Query.filter(attribute == ^attribute)
    |> Ash.read_one!()
  end

  defp pr(opts) do
    %PullRequest{
      node_id: opts[:node_id],
      number: opts[:number],
      state: opts[:state] || :open,
      base_ref: opts[:base_ref] || "master",
      head_ref: opts[:head_ref] || "feature",
      head_sha: opts[:head_sha] || "default_sha",
      title: opts[:title] || "pr #{opts[:number]}",
      updated_at: opts[:updated_at] || ~U[2026-04-23 12:00:00Z],
      closed_at: opts[:closed_at],
      merged_at: opts[:merged_at],
      merge_commit_sha: opts[:merge_commit_sha],
      labels: opts[:labels] || []
    }
  end

  defp hours_ago(n) do
    DateTime.utc_now(:microsecond) |> DateTime.add(-n * 3600, :second)
  end

  defp number_of("pr_old"), do: 1
  defp number_of("pr_newer"), do: 2
  defp number_of(other), do: :erlang.phash2(other, 10_000)

  defp transition_recorder do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    fun = fn change, reason -> Agent.update(agent, &[{change, reason} | &1]) end
    calls = fn -> Agent.get(agent, &Enum.reverse/1) end
    %{fn: fun, calls: calls}
  end

  defp fetcher_returning(fun) do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    fetcher = fn ids ->
      Agent.update(agent, &[ids | &1])
      {:ok, fun.(ids)}
    end

    calls = fn -> Agent.get(agent, &Enum.reverse/1) end
    %{fn: fetcher, calls: calls}
  end
end

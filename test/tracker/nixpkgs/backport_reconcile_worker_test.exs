defmodule Tracker.Nixpkgs.BackportReconcileWorkerTest do
  use Tracker.DataCase, async: true

  alias Tracker.GitHub.GraphQL.PullRequest
  alias Tracker.Nixpkgs.{BackportLink, BackportReconcileWorker, Change, ChangeDiscoveryWorker}

  test "cron cannot overlap a reconciliation that takes longer than one minute" do
    job = %{} |> BackportReconcileWorker.new() |> Oban.insert!()

    Repo.update_all(from(job_row in Oban.Job, where: job_row.id == ^job.id),
      set: [state: "executing", inserted_at: DateTime.add(DateTime.utc_now(), -120, :second)]
    )

    duplicate = %{} |> BackportReconcileWorker.new() |> Oban.insert!()
    assert duplicate.id == job.id
  end

  test "imports missing originals through discovery, preserving directed links and idempotency" do
    backport = pr(200, "Backport of #100", "release-26.05")
    ChangeDiscoveryWorker.upsert_pulls([backport])

    fetch = fn numbers ->
      {:ok, Map.new(numbers, &{&1, {:pull_request, if(&1 == 200, do: backport, else: pr(&1))}})}
    end

    opts = [fetcher: fetch, commits_fetcher: fn _ -> {:ok, []} end]

    assert {:ok, 1} = BackportReconcileWorker.run([200], opts)
    assert Change.get_by_number!(100).number == 100
    assert [link] = BackportLink.for_change!(100)
    assert link.source_number == 100
    assert link.backport.number == 200
    assert link.original.number == 100
    assert link.confidence == :confirmed
    assert {:ok, 1} = BackportReconcileWorker.run([200], opts)
    assert [_] = BackportLink.for_change!(200)
  end

  test "replaces stale evidence on body-only edits and removes obsolete links" do
    ChangeDiscoveryWorker.upsert_pulls([pr(300, "Backport of #100")])

    run = fn body ->
      BackportReconcileWorker.run([300],
        fetcher: fn numbers ->
          {:ok,
           Map.new(numbers, &{&1, {:pull_request, pr(&1, if(&1 == 300, do: body, else: ""))}})}
        end,
        commits_fetcher: fn _ -> {:ok, []} end
      )
    end

    assert {:ok, 1} = run.("Backport of #100")
    assert [%{source_number: 100}] = BackportLink.for_change!(300)
    assert {:ok, 1} = run.("Backport of #101")
    assert [%{source_number: 101}] = BackportLink.for_change!(300)
    assert [] = BackportLink.for_change!(100)
    assert {:ok, 1} = run.("Fixes #101")
    assert [] = BackportLink.for_change!(300)
  end

  test "persists unresolved references on import failures and retries" do
    backport = pr(400, "Backport of #99")
    ChangeDiscoveryWorker.upsert_pulls([backport])

    fetch = fn
      [400] -> {:ok, %{400 => {:pull_request, backport}}}
      [99] -> {:error, :temporarily_unavailable}
    end

    assert {:error, :temporarily_unavailable} =
             BackportReconcileWorker.run([400],
               fetcher: fetch,
               commits_fetcher: fn _ -> {:ok, []} end
             )

    assert [link] = BackportLink.for_change!(400)
    assert link.source_number == 99
    assert link.original == nil
    assert Change.get_by_number!(400).backport_retry_at

    retry_fetch = fn numbers ->
      {:ok, Map.new(numbers, &{&1, {:pull_request, if(&1 == 400, do: backport, else: pr(&1))}})}
    end

    assert {:ok, 1} =
             BackportReconcileWorker.run([400],
               fetcher: retry_fetch,
               commits_fetcher: fn _ -> {:ok, []} end
             )

    assert [%{original: %{number: 99}, source_status: :imported}] = BackportLink.for_change!(400)
    refute Change.get_by_number!(400).backport_pending
  end

  test "issues and unavailable PRs never become Changes" do
    backport = pr(500, "Backport of #90 and #91")
    ChangeDiscoveryWorker.upsert_pulls([backport])

    fetch = fn
      [500] -> {:ok, %{500 => {:pull_request, backport}}}
      numbers -> {:ok, Map.new(numbers, &{&1, if(&1 == 90, do: :issue, else: :not_found)})}
    end

    assert {:ok, 1} =
             BackportReconcileWorker.run([500],
               fetcher: fetch,
               commits_fetcher: fn _ -> {:ok, []} end
             )

    assert length(BackportLink.for_change!(500)) == 2
    assert Change.get_by_number(90) |> elem(0) == :error
    assert Change.get_by_number(91) |> elem(0) == :error
    links = BackportLink.for_change!(500)

    assert Enum.any?(
             links,
             &(&1.source_number == 90 and &1.source_status == :issue and
                 &1.confidence == :candidate)
           )

    assert Enum.any?(links, &(&1.source_number == 91 and &1.source_status == :not_found))
    assert DateTime.after?(Change.get_by_number!(500).backport_retry_at, DateTime.utc_now())
    refute 500 in Enum.map(Change.backport_backlog!(), & &1.number)
  end

  test "historical backlog includes merged and closed Changes and batches number lookups" do
    for number <- 600..626 do
      Change.bulk_upsert_all([%{number: number, title: "Historical", state: :closed}])
    end

    parent = self()

    fetch = fn numbers ->
      send(parent, {:batch, numbers})
      {:ok, Map.new(numbers, &{&1, {:pull_request, %{pr(&1) | state: :closed}}})}
    end

    assert {:ok, 25} =
             BackportReconcileWorker.run(nil,
               fetcher: fetch,
               commits_fetcher: fn _ -> {:ok, []} end
             )

    assert_receive {:batch, numbers}
    assert length(numbers) == 25

    assert {:ok, 2} =
             BackportReconcileWorker.run(nil,
               fetcher: fetch,
               commits_fetcher: fn _ -> {:ok, []} end
             )
  end

  test "commit trailers resolve all associations and preserve ambiguity" do
    backport = pr(700)
    ChangeDiscoveryWorker.upsert_pulls([backport])
    sha = String.duplicate("a", 40)
    fetch = fn numbers -> {:ok, Map.new(numbers, &{&1, {:pull_request, pr(&1)}})} end

    assert {:ok, 1} =
             BackportReconcileWorker.run([700],
               fetcher: fetch,
               commits_fetcher: fn 700 ->
                 {:ok, ["change\n(cherry picked from commit #{sha})"]}
               end,
               associations_fetcher: fn [^sha] -> {:ok, %{sha => [701, 702]}} end
             )

    assert links = BackportLink.for_change!(700)
    assert Enum.sort(Enum.map(links, & &1.source_number)) == [701, 702]
    assert Enum.all?(links, &(&1.confidence == :candidate))
  end

  test "deduplicates shared missing originals and imports them in bounded batches" do
    body = "Backport of " <> Enum.map_join(1..26, ", ", &"##{&1}")
    pulls = [pr(800, body), pr(801, body)]
    ChangeDiscoveryWorker.upsert_pulls(pulls)

    fetch = fn numbers ->
      send(self(), {:lookup, numbers})
      assert length(numbers) <= 25

      {:ok,
       Map.new(numbers, fn number ->
         {number, {:pull_request, Enum.find(pulls, &(&1.number == number)) || pr(number)}}
       end)}
    end

    assert {:ok, 2} =
             BackportReconcileWorker.run([800, 801],
               fetcher: fetch,
               commits_fetcher: fn _ -> {:ok, []} end
             )

    assert_receive {:lookup, [800, 801]}
    assert_receive {:lookup, first}
    assert_receive {:lookup, second}
    assert length(first) == 25
    assert length(second) == 1
    assert Enum.sort(first ++ second) == Enum.to_list(1..26)
    refute_receive {:lookup, _}
    assert length(BackportLink.for_change!(800)) == 26
    assert length(BackportLink.for_change!(801)) == 26
  end

  test "native metadata refresh and upsert invalidate evidence without a state transition" do
    ChangeDiscoveryWorker.upsert_pulls([pr(900)])
    change = Change.get_by_number!(900)

    change =
      Change.mark_backport_checked!(change, %{
        backport_retry_at: nil,
        expected_version: change.backport_version
      })

    refute change.backport_pending
    edited = Change.refresh_from_graphql!(change, %{body: "Backport of #901"})
    assert edited.backport_pending
    assert edited.body == "Backport of #901"

    checked =
      Change.mark_backport_checked!(edited, %{
        backport_retry_at: nil,
        expected_version: edited.backport_version
      })

    upserted =
      Change.bulk_upsert!(900, %{
        title: checked.title,
        state: checked.state,
        body: "Backport of #902"
      })

    assert upserted.backport_pending
    assert upserted.body == "Backport of #902"
  end

  test "failed commit evidence is deferred without blocking successful or later Changes" do
    ChangeDiscoveryWorker.upsert_pulls(Enum.map(1000..1025, &pr/1))
    fetch = fn numbers -> {:ok, Map.new(numbers, &{&1, {:pull_request, pr(&1)}})} end

    commits = fn
      1000 -> {:error, :unavailable_commit}
      _ -> {:ok, []}
    end

    opts = [fetcher: fetch, commits_fetcher: commits]
    assert {:error, :unavailable_commit} = BackportReconcileWorker.run(nil, opts)
    refute Change.get_by_number!(1001).backport_pending
    assert Change.get_by_number!(1000).backport_retry_at
    assert {:ok, 1} = BackportReconcileWorker.run(nil, opts)
    refute Change.get_by_number!(1025).backport_pending
  end

  test "concurrent metadata edits are not marked reconciled against older evidence" do
    ChangeDiscoveryWorker.upsert_pulls([pr(1100)])
    fetch = fn numbers -> {:ok, Map.new(numbers, &{&1, {:pull_request, pr(&1)}})} end

    commits = fn 1100 ->
      change = Change.get_by_number!(1100)
      Change.refresh_from_graphql!(change, %{body: "Backport of #1101"})
      {:ok, []}
    end

    assert {:ok, 1} =
             BackportReconcileWorker.run([1100], fetcher: fetch, commits_fetcher: commits)

    assert Change.get_by_number!(1100).backport_pending
    assert Enum.any?(Change.backport_backlog!(), &(&1.number == 1100))
  end

  test "known issue references stay candidates when a later lookup fails" do
    backport = pr(1200, "Backport of #1201")
    ChangeDiscoveryWorker.upsert_pulls([backport])

    fetch = fn
      [1200] -> {:ok, %{1200 => {:pull_request, backport}}}
      [1201] -> {:ok, %{1201 => :issue}}
    end

    assert {:ok, 1} =
             BackportReconcileWorker.run([1200],
               fetcher: fetch,
               commits_fetcher: fn _ -> {:ok, []} end
             )

    retry = fn
      [1200] -> {:ok, %{1200 => {:pull_request, backport}}}
      [1201] -> {:error, :temporary}
    end

    assert {:error, :temporary} =
             BackportReconcileWorker.run([1200],
               fetcher: retry,
               commits_fetcher: fn _ -> {:ok, []} end
             )

    assert [%{source_status: :issue, confidence: :candidate}] = BackportLink.for_change!(1200)
  end

  test "unavailable historical PRs with no evidence version are retried without blocking the backlog" do
    Change.bulk_upsert_all([%{number: 1300, title: "Historical", state: :closed}])

    Repo.update_all(from(change in Change, where: change.number == 1300),
      set: [backport_version: nil]
    )

    assert {:ok, 1} =
             BackportReconcileWorker.run([1300],
               fetcher: fn [1300] -> {:ok, %{1300 => :not_found}} end
             )

    change = Change.get_by_number!(1300)
    refute change.backport_pending
    assert change.backport_retry_at
    assert [] == Change.backport_backlog!()
  end

  test "transient batch fetch errors defer records and preserve existing evidence" do
    Change.bulk_upsert_all([%{number: 1400, title: "Historical", state: :merged}])

    assert {:error, :network} =
             BackportReconcileWorker.run([1400], fetcher: fn _ -> {:error, :network} end)

    assert Change.get_by_number!(1400).backport_retry_at
    assert [] == Change.backport_backlog!()
  end

  defp pr(number, body \\ "", base_ref \\ "master") do
    %PullRequest{
      node_id: "PR_#{number}",
      number: number,
      title: "Change #{number}",
      body: body,
      state: :merged,
      base_ref: base_ref,
      head_sha: "head#{number}",
      updated_at: ~U[2026-11-01 00:00:00Z]
    }
  end
end

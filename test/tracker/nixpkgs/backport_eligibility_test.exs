defmodule Tracker.Nixpkgs.BackportEligibilityTest do
  use Tracker.DataCase, async: true

  alias Tracker.GitHub.GraphQL.PullRequest
  alias Tracker.Nixpkgs.{BackportReconcileWorker, Change, ChangeDiscoveryWorker}

  setup do
    pr = %PullRequest{
      node_id: "PR_1500",
      number: 1500,
      title: "Unchanged PR",
      body: "",
      state: :open,
      head_sha: "head1500",
      updated_at: ~U[2026-11-01 00:00:00Z]
    }

    ChangeDiscoveryWorker.upsert_pulls([pr])

    opts = [
      fetcher: fn [1500] -> {:ok, %{1500 => {:pull_request, pr}}} end,
      commits_fetcher: fn 1500 -> {:ok, []} end
    ]

    assert {:ok, 1} = BackportReconcileWorker.run(nil, opts)
    %{pr: pr, opts: opts}
  end

  test "identical discovery, refresh and native upsert do not repeat reconciliation", %{
    pr: pr,
    opts: opts
  } do
    checked = Change.get_by_number!(1500)
    attrs = ChangeDiscoveryWorker.parse_pr_payload(pr)

    writers = [
      fn -> ChangeDiscoveryWorker.upsert_pulls([pr]) end,
      fn ->
        Change.refresh_from_graphql!(Change.get_by_number!(1500), %{
          body: pr.body,
          head_sha: pr.head_sha,
          gh_updated_at: pr.updated_at
        })
      end,
      fn -> Change.bulk_upsert!(1500, Map.delete(attrs, :number)) end
    ]

    for write <- writers do
      write.()
      assert {:ok, 0} = BackportReconcileWorker.run(nil, opts)
      assert Change.get_by_number!(1500).backport_checked_at == checked.backport_checked_at
    end
  end

  test "a newer GitHub updatedAt makes identical PR metadata eligible", %{pr: pr} do
    updated = %{pr | updated_at: DateTime.add(pr.updated_at, 1, :second)}
    ChangeDiscoveryWorker.upsert_pulls([updated])
    assert [change] = Change.backport_backlog!()
    assert change.number == 1500

    opts = [
      fetcher: fn [1500] -> {:ok, %{1500 => {:pull_request, updated}}} end,
      commits_fetcher: fn _ -> {:ok, []} end
    ]

    assert {:ok, 1} = BackportReconcileWorker.run(nil, opts)
    assert [] = Change.backport_backlog!()
  end

  test "unchanged refresh preserves a scheduled retry without running it early", %{
    pr: pr,
    opts: opts
  } do
    unavailable = %{pr | body: "Backport of #1501"}

    fetcher = fn
      [1500] -> {:ok, %{1500 => {:pull_request, unavailable}}}
      [1501] -> {:ok, %{1501 => :not_found}}
    end

    assert {:ok, 1} = BackportReconcileWorker.run([1500], Keyword.put(opts, :fetcher, fetcher))
    checked = Change.get_by_number!(1500)
    assert checked.backport_retry_at
    ChangeDiscoveryWorker.upsert_pulls([unavailable])
    assert {:ok, 0} = BackportReconcileWorker.run(nil, opts)
    assert Change.get_by_number!(1500).backport_retry_at == checked.backport_retry_at
  end

  test "a due retry runs even when GitHub updatedAt is unchanged", %{pr: pr, opts: opts} do
    Change.mark_backport_checked!(Change.get_by_number!(1500), %{
      backport_gh_updated_at: pr.updated_at,
      backport_retry_at: DateTime.add(DateTime.utc_now(), -1, :second)
    })

    assert {:ok, 1} = BackportReconcileWorker.run(nil, opts)
    assert [] = Change.backport_backlog!()
    assert Change.get_by_number!(1500).backport_retry_at == nil
  end

  test "an identical refresh during reconciliation does not schedule another pass", %{pr: pr} do
    updated = %{pr | updated_at: DateTime.add(pr.updated_at, 1, :second)}
    ChangeDiscoveryWorker.upsert_pulls([updated])

    opts = [
      fetcher: fn [1500] -> {:ok, %{1500 => {:pull_request, updated}}} end,
      commits_fetcher: fn 1500 ->
        Change.refresh_from_graphql!(Change.get_by_number!(1500), %{
          gh_updated_at: updated.updated_at
        })

        {:ok, []}
      end
    ]

    assert {:ok, 1} = BackportReconcileWorker.run(nil, opts)
    assert [] = Change.backport_backlog!()
  end

  test "previously checked records without a GitHub checkpoint are reconciled once", %{opts: opts} do
    Change.mark_backport_checked!(Change.get_by_number!(1500), %{backport_gh_updated_at: nil})
    assert {:ok, 1} = BackportReconcileWorker.run(nil, opts)
    assert {:ok, 0} = BackportReconcileWorker.run(nil, opts)
  end
end

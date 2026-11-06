defmodule Tracker.Nixpkgs.BackportPriorityTest do
  use Tracker.DataCase, async: true

  alias Tracker.GitHub.GraphQL.PullRequest
  alias Tracker.Nixpkgs.{BackportReconcileWorker, Change}

  test "due retries lead, newest PR activity follows and five oldest backfill slots remain" do
    insert_changes(1..40, ~U[2020-01-01 00:00:00Z])
    insert_changes(100..129, ~U[2026-11-06 00:00:00Z])
    insert_changes(200..201, ~U[2019-01-01 00:00:00Z])
    schedule_retries(200..201)

    assert selected_batch() == [200, 201] ++ Enum.to_list(129..112//-1) ++ Enum.to_list(1..5)
  end

  test "a retry flood cannot consume the historical reservation" do
    insert_changes(1..40, ~U[2020-01-01 00:00:00Z])
    insert_changes(200..229, ~U[2019-01-01 00:00:00Z])
    schedule_retries(200..229)

    assert selected_batch() == Enum.to_list(200..219) ++ Enum.to_list(1..5)
  end

  test "newest metadata edits use all 25 slots when historical backfill is exhausted" do
    insert_changes(100..129, ~U[2026-11-06 00:00:00Z])

    for change <- Change.by_numbers!(Enum.to_list(100..129)) do
      Change.mark_backport_checked!(change, %{
        backport_gh_updated_at: DateTime.add(change.gh_updated_at, -1, :second)
      })
    end

    assert selected_batch() == Enum.to_list(129..105//-1)
    assert selected_batch() == Enum.to_list(104..100//-1)
  end

  test "a short historical backlog gives unused reserved slots to priority work" do
    insert_changes(1..3, ~U[2020-01-01 00:00:00Z])
    insert_changes(200..229, ~U[2019-01-01 00:00:00Z])
    schedule_retries(200..229)

    batch = selected_batch()
    assert batch == Enum.to_list(200..221) ++ Enum.to_list(1..3)
    assert length(Enum.uniq(batch)) == 25
  end

  test "a short backlog is drained without duplicate selections" do
    insert_changes(1..10, ~U[2020-01-01 00:00:00Z])
    batch = selected_batch()
    assert Enum.sort(batch) == Enum.to_list(1..10)
    assert selected_batch() == []
  end

  defp insert_changes(numbers, timestamp) do
    numbers
    |> Enum.map(fn number ->
      %{
        number: number,
        title: "PR #{number}",
        state: :closed,
        gh_updated_at: DateTime.add(timestamp, number, :second)
      }
    end)
    |> Change.bulk_upsert_all()
  end

  defp schedule_retries(numbers) do
    for change <- Change.by_numbers!(Enum.to_list(numbers)) do
      Change.mark_backport_checked!(change, %{
        backport_gh_updated_at: change.gh_updated_at,
        backport_retry_at: DateTime.add(DateTime.utc_now(), change.number - 1000, :second)
      })
    end
  end

  defp selected_batch do
    fetcher = fn numbers ->
      send(self(), {:selected, numbers})

      results =
        Map.new(Change.by_numbers!(numbers), fn change ->
          pr = %PullRequest{
            node_id: "PR_#{change.number}",
            number: change.number,
            title: change.title,
            state: change.state,
            head_sha: "head#{change.number}",
            updated_at: change.gh_updated_at
          }

          {change.number, {:pull_request, pr}}
        end)

      {:ok, results}
    end

    assert {:ok, _count} =
             BackportReconcileWorker.run(nil,
               fetcher: fetcher,
               commits_fetcher: fn _ -> {:ok, []} end
             )

    receive do
      {:selected, numbers} -> numbers
    after
      0 -> []
    end
  end
end

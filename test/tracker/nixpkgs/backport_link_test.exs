defmodule Tracker.Nixpkgs.BackportLinkTest do
  use Tracker.DataCase, async: true

  alias Tracker.Nixpkgs.{BackportLink, Change}

  test "a newer GitHub timestamp preserves check order so historical Changes cannot starve" do
    timestamp = ~U[2026-11-01 00:00:00Z]

    Change.bulk_upsert_all([
      %{number: 10, title: "Active", state: :open, gh_updated_at: timestamp}
    ])

    change = Change.get_by_number!(10)

    checked =
      Change.mark_backport_checked!(change, %{
        backport_retry_at: nil,
        backport_gh_updated_at: timestamp
      })

    Change.bulk_upsert_all([%{number: 11, title: "Historical", state: :merged}])

    Change.bulk_upsert_all([
      %{
        number: 10,
        title: "Edited",
        state: :open,
        gh_updated_at: DateTime.add(timestamp, 1, :second)
      }
    ])

    edited = Change.get_by_number!(10)
    assert edited.backport_checked_at == checked.backport_checked_at
    assert Enum.map(Change.backport_backlog!(), & &1.number) == [11, 10]
  end

  test "retains source numbers before source discovery and loads both directions afterwards" do
    ids =
      Change.bulk_upsert_all([
        %{number: 2, title: "Backport", state: :merged, base_ref: "staging-26.05"}
      ])

    BackportLink.create!(%{
      source_number: 1,
      backport_id: ids[2],
      confidence: :confirmed,
      evidence: ["body"]
    })

    assert [%{original: nil}] = BackportLink.for_change!(2)
    Change.bulk_upsert_all([%{number: 1, title: "Original", state: :closed}])
    assert [link] = BackportLink.for_change!(1)
    assert link.original.number == 1
    assert link.backport.base_ref == "staging-26.05"
    assert link.backport.state == :merged
  end

  test "supports multiple originals and backports, upserting repeated evidence" do
    ids = Change.bulk_upsert_all(for n <- 1..4, do: %{number: n, title: "PR #{n}", state: :open})

    for {source, backport} <- [{1, 3}, {1, 4}, {2, 3}, {1, 3}] do
      BackportLink.create!(%{
        source_number: source,
        backport_id: ids[backport],
        confidence: :candidate,
        evidence: ["head_ref"]
      })
    end

    assert length(BackportLink.for_change!(1)) == 2
    assert length(BackportLink.for_change!(3)) == 2
  end
end

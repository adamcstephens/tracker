defmodule Tracker.Ingestion.IngestionToolsTest do
  use Tracker.DataCase, async: true

  alias Tracker.Accounts.User
  alias Tracker.Ingestion.IngestionRun

  test "investigation read includes unfinished overlapping runs and excludes later runs" do
    admin = %User{roles: [:admin]}
    unfinished = IngestionRun.create!(%{type: :cron_update, started_at: ~U[2026-01-01 00:00:00Z]})
    IngestionRun.create!(%{type: :cron_update, started_at: ~U[2026-01-04 00:00:00Z]})

    assert %{results: [run]} =
             IngestionRun.list_ingestion_runs!(~U[2026-01-02 00:00:00Z], ~U[2026-01-03 00:00:00Z],
               actor: admin
             )

    assert run.id == unfinished.id
  end

  test "completed runs outside the requested window are excluded" do
    completed =
      IngestionRun.create!(%{type: :cron_update, started_at: ~U[2026-01-01 00:00:00Z]})
      |> IngestionRun.mark_completed!()

    page =
      IngestionRun.list_ingestion_runs!(~U[2100-01-01 00:00:00Z], ~U[2100-01-02 00:00:00Z],
        actor: %User{roles: [:admin]}
      )

    refute Enum.any?(page.results, &(&1.id == completed.id))
  end

  test "investigation read denies absent and non-admin actors" do
    IngestionRun.create!(%{type: :cron_update, started_at: ~U[2026-01-01 00:00:00Z]})

    for actor <- [nil, %User{roles: [:user]}] do
      assert {:error, %Ash.Error.Forbidden{}} =
               IngestionRun.list_ingestion_runs(
                 ~U[2026-01-02 00:00:00Z],
                 ~U[2026-01-03 00:00:00Z],
                 actor: actor,
                 authorize?: true
               )
    end
  end

  test "investigation read is bounded" do
    for _ <- 1..51 do
      IngestionRun.create!(%{type: :cron_update, started_at: ~U[2026-01-01 00:00:00Z]})
    end

    page =
      IngestionRun.list_ingestion_runs!(~U[2026-01-02 00:00:00Z], ~U[2026-01-03 00:00:00Z],
        actor: %User{roles: [:admin]}
      )

    assert length(page.results) == 50
    assert page.more?
    assert %{results: [_], more?: false} = Ash.page!(page, :next)
  end
end

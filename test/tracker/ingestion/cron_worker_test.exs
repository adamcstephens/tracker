defmodule Tracker.Ingestion.CronWorkerTest do
  use Tracker.DataCase, async: false

  alias Tracker.Ingestion.{CronWorker, Pipeline, IngestionRun}
  alias Tracker.Nixpkgs.{Channel, ReleaseCache}
  alias Tracker.Nixpkgs.ReleaseCache.Release

  @cache_name :cron_worker_test_cache

  setup do
    {:ok, _pid} = ReleaseCache.start_link(name: @cache_name, load: false)

    channel =
      Channel.create!(%{
        name: "nixos-unstable",
        display_name: "NixOS Unstable",
        branch: "nixos-unstable",
        status: :active,
        is_stable: false
      })

    # Seed a completed pipeline so sync_channel doesn't return :noop
    run = IngestionRun.create!(%{type: :cron_update, started_at: DateTime.utc_now()})

    Pipeline.create!(%{
      channel_id: channel.id,
      revision: "aaa1111" <> String.duplicate("0", 33),
      base_url: "https://releases.nixos.org/nixos/unstable/nixos-25.05pre-aaa1111",
      released_at: ~U[2025-06-01 00:00:00Z],
      active_steps: [:create_revision, :load_packages, :detect_package_events, :finalize],
      sequence: 0,
      ingestion_run_id: run.id
    })
    |> Pipeline.start!()
    |> Pipeline.mark_completed!()

    releases = [
      %Release{
        base_url: "https://releases.nixos.org/nixos/unstable/nixos-25.05pre-bbb2222",
        released_at: ~U[2025-06-10 00:00:00Z],
        revision: "bbb2222" <> String.duplicate("0", 33)
      },
      %Release{
        base_url: "https://releases.nixos.org/nixos/unstable/nixos-25.05pre-aaa1111",
        released_at: ~U[2025-06-01 00:00:00Z],
        revision: "aaa1111" <> String.duplicate("0", 33)
      }
    ]

    ReleaseCache.put_releases(@cache_name, "nixos-unstable", releases)

    {:ok, channel: channel}
  end

  describe "perform/1" do
    test "syncs all active channels from the database", %{channel: channel} do
      # Also create a retired channel that should NOT be synced
      Channel.create!(%{
        name: "nixos-retired",
        display_name: "NixOS Retired",
        branch: "nixos-retired",
        status: :retired,
        is_stable: false
      })

      pipelines_before = length(Pipeline.for_channel!(channel.id))

      assert :ok =
               perform_job(CronWorker, %{}, queue: :ingestion)

      # The active channel should have new pipeline(s) created
      pipelines_after = length(Pipeline.for_channel!(channel.id))
      assert pipelines_after > pipelines_before
    end

    test "succeeds with no active channels" do
      # Delete the channel created in setup by retiring it
      # We can't easily delete Ash resources, so create a fresh test
      # Just verify the worker doesn't crash with empty results
      Tracker.Repo.delete_all(Tracker.Ingestion.Pipeline)
      Tracker.Repo.delete_all(Tracker.Ingestion.IngestionRun)
      Tracker.Repo.delete_all(Tracker.Nixpkgs.Channel)

      assert :ok = perform_job(CronWorker, %{}, queue: :ingestion)
    end
  end
end

defmodule Tracker.Ingestion.Steps.CreateRevisionTest do
  use Tracker.DataCase, async: false

  alias Tracker.Ingestion.{IngestionRun, Pipeline}
  alias Tracker.Ingestion.StepContext
  alias Tracker.Ingestion.Steps.CreateRevision
  alias Tracker.Nixpkgs.{Channel, ChangeBranchDetectionWorker, ChannelRevision}

  setup do
    channel =
      Channel.create!(%{
        name: "nixos-unstable",
        display_name: "NixOS Unstable",
        status: :active,
        is_stable: false
      })

    run = IngestionRun.create!(%{type: :cron_update, started_at: DateTime.utc_now()})

    pipeline =
      Pipeline.create!(%{
        channel_id: channel.id,
        revision: String.duplicate("a", 40),
        base_url: "https://releases.nixos.org/nixos/unstable/nixos-25.05pre-aaa",
        released_at: ~U[2026-04-23 00:00:00Z],
        active_steps: [:create_revision],
        sequence: 0,
        ingestion_run_id: run.id
      })

    %{channel: channel, pipeline: pipeline}
  end

  test "creates ChannelRevision and enqueues ChangeBranchDetectionWorker", %{pipeline: pipeline} do
    assert :ok = CreateRevision.run(%StepContext{pipeline: pipeline})

    assert {:ok, %ChannelRevision{}} =
             ChannelRevision.find(pipeline.channel_id, pipeline.revision)

    assert_enqueued(worker: ChangeBranchDetectionWorker)
  end
end

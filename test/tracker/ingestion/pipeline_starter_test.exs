defmodule Tracker.Ingestion.PipelineStarterTest do
  use Tracker.DataCase, async: false

  alias Tracker.Ingestion.{IngestionRun, Pipeline, PipelineStarter}
  alias Tracker.Nixpkgs.{Channel, ReleaseCache}
  alias Tracker.Nixpkgs.ReleaseCache.Release

  @channel_name "nixos-unstable"
  @cache_name :test_release_cache

  setup do
    {:ok, _pid} = ReleaseCache.start_link(name: @cache_name, load: false)

    channel =
      Channel.create!(%{
        name: @channel_name,
        display_name: "NixOS Unstable",
        branch: "nixos-unstable",
        status: :active,
        is_stable: false
      })

    # Releases must be sorted desc (newest first) to match ReleaseCache's internal ordering
    releases = [
      %Release{
        short_hash: "ccc3333",
        base_url: "https://releases.nixos.org/nixos/unstable/nixos-25.05pre-ccc3333",
        released_at: "2025-06-20T00:00:00Z"
      },
      %Release{
        short_hash: "bbb2222",
        base_url: "https://releases.nixos.org/nixos/unstable/nixos-25.05pre-bbb2222",
        released_at: "2025-06-10T00:00:00Z"
      },
      %Release{
        short_hash: "aaa1111",
        base_url: "https://releases.nixos.org/nixos/unstable/nixos-25.05pre-aaa1111",
        released_at: "2025-06-01T00:00:00Z"
      }
    ]

    ReleaseCache.put_releases(@cache_name, @channel_name, releases)

    # Revision resolver that returns a fake full hash based on short_hash
    revision_resolver = fn release -> release.short_hash <> String.duplicate("0", 33) end

    {:ok, channel: channel, revision_resolver: revision_resolver}
  end

  describe "sync_channel/2 with bootstrap: false" do
    test "returns :noop when no completed pipelines exist", %{
      channel: channel,
      revision_resolver: resolver
    } do
      result =
        PipelineStarter.sync_channel(channel,
          cache: @cache_name,
          revision_resolver: resolver
        )

      assert result == :noop
    end

    test "creates pipelines for releases newer than last completed", %{
      channel: channel,
      revision_resolver: resolver
    } do
      # Create a completed pipeline for the first release
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

      {:ok, count} =
        PipelineStarter.sync_channel(channel,
          cache: @cache_name,
          revision_resolver: resolver
        )

      assert count == 2

      pipelines =
        Pipeline.for_channel!(channel.id)
        |> Enum.sort_by(& &1.sequence)

      # Original + 2 new
      assert length(pipelines) == 3
    end

    test "skips releases that already have non-failed pipelines", %{
      channel: channel,
      revision_resolver: resolver
    } do
      run = IngestionRun.create!(%{type: :cron_update, started_at: DateTime.utc_now()})

      # Completed pipeline for first release
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

      # Pending pipeline for second release (should be skipped)
      Pipeline.create!(%{
        channel_id: channel.id,
        revision: "bbb2222" <> String.duplicate("0", 33),
        base_url: "https://releases.nixos.org/nixos/unstable/nixos-25.05pre-bbb2222",
        released_at: ~U[2025-06-10 00:00:00Z],
        active_steps: [:create_revision, :load_packages, :detect_package_events, :finalize],
        sequence: 1,
        ingestion_run_id: run.id
      })

      {:ok, count} =
        PipelineStarter.sync_channel(channel,
          cache: @cache_name,
          revision_resolver: resolver
        )

      # Only the third release should be created
      assert count == 1
    end
  end

  describe "sync_channel/2 with bootstrap: true" do
    test "creates pipelines for all releases", %{
      channel: channel,
      revision_resolver: resolver
    } do
      {:ok, count} =
        PipelineStarter.sync_channel(channel,
          bootstrap: true,
          cache: @cache_name,
          revision_resolver: resolver
        )

      assert count == 3
    end

    test "creates pipelines for releases after the given date", %{
      channel: channel,
      revision_resolver: resolver
    } do
      {:ok, count} =
        PipelineStarter.sync_channel(channel,
          bootstrap: true,
          after: ~U[2025-06-05 00:00:00Z],
          cache: @cache_name,
          revision_resolver: resolver
        )

      assert count == 2
    end
  end

  describe "predecessor linking" do
    test "each pipeline has correct predecessor_id", %{
      channel: channel,
      revision_resolver: resolver
    } do
      {:ok, _count} =
        PipelineStarter.sync_channel(channel,
          bootstrap: true,
          cache: @cache_name,
          revision_resolver: resolver
        )

      pipelines =
        Pipeline.for_channel!(channel.id)
        |> Enum.sort_by(& &1.sequence)

      [first, second, third] = pipelines

      # First pipeline has no predecessor
      assert first.predecessor_id == nil
      # Second links to first
      assert second.predecessor_id == first.id
      # Third links to second
      assert third.predecessor_id == second.id
    end

    test "cross-run predecessor linking works", %{
      channel: channel,
      revision_resolver: resolver
    } do
      # Create a completed pipeline for the first release (prior run)
      run = IngestionRun.create!(%{type: :backfill, started_at: DateTime.utc_now()})

      prior_pipeline =
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

      # Sync creates new pipelines that link back to the prior run's pipeline
      {:ok, _count} =
        PipelineStarter.sync_channel(channel,
          cache: @cache_name,
          revision_resolver: resolver
        )

      new_pipelines =
        Pipeline.for_channel!(channel.id)
        |> Enum.reject(&(&1.id == prior_pipeline.id))
        |> Enum.sort_by(& &1.sequence)

      [second, third] = new_pipelines

      # Second pipeline's predecessor is the prior run's pipeline
      assert second.predecessor_id == prior_pipeline.id
      assert third.predecessor_id == second.id
    end
  end

  describe "backfill_channel/2" do
    test "raises when channel already has pipelines", %{
      channel: channel,
      revision_resolver: resolver
    } do
      run = IngestionRun.create!(%{type: :cron_update, started_at: DateTime.utc_now()})

      Pipeline.create!(%{
        channel_id: channel.id,
        revision: "existing",
        base_url: "https://example.com",
        released_at: ~U[2025-06-01 00:00:00Z],
        active_steps: [:create_revision],
        sequence: 0,
        ingestion_run_id: run.id
      })

      assert_raise ArgumentError, fn ->
        PipelineStarter.backfill_channel(channel,
          cache: @cache_name,
          revision_resolver: resolver
        )
      end
    end

    test "delegates to sync_channel with bootstrap: true", %{
      channel: channel,
      revision_resolver: resolver
    } do
      {:ok, count} =
        PipelineStarter.backfill_channel(channel,
          cache: @cache_name,
          revision_resolver: resolver
        )

      assert count == 3
    end

    test "passes after option through", %{
      channel: channel,
      revision_resolver: resolver
    } do
      {:ok, count} =
        PipelineStarter.backfill_channel(channel,
          after: ~U[2025-06-05 00:00:00Z],
          cache: @cache_name,
          revision_resolver: resolver
        )

      assert count == 2
    end
  end
end

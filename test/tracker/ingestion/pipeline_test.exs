defmodule Tracker.Ingestion.PipelineTest do
  use Tracker.DataCase, async: true

  alias Tracker.Ingestion.{IngestionRun, Pipeline}

  defp create_run! do
    IngestionRun.create!(%{type: :cron_update, started_at: DateTime.utc_now()})
  end

  defp create_pipeline!(run, attrs \\ %{}) do
    defaults = %{
      channel: "nixos-unstable",
      revision: "abc123",
      base_url: "https://releases.nixos.org/nixos/unstable/nixos-25.05pre123",
      released_at: DateTime.utc_now(),
      active_steps: [:create_revision, :load_packages, :detect_package_events, :finalize],
      sequence: 0,
      ingestion_run_id: run.id
    }

    Pipeline.create!(Map.merge(defaults, attrs))
  end

  describe "create" do
    test "creates a pipeline with pending status and empty completed_steps" do
      run = create_run!()
      pipeline = create_pipeline!(run)

      assert pipeline.status == :pending
      assert pipeline.completed_steps == []
      assert length(pipeline.active_steps) == 4
    end
  end

  describe "complete_step" do
    test "atomically appends a step to completed_steps" do
      run = create_run!()
      pipeline = create_pipeline!(run)
      Pipeline.start!(pipeline)

      updated = Pipeline.complete_step!(pipeline, :create_revision)

      assert :create_revision in updated.completed_steps
    end

    test "appends multiple steps sequentially" do
      run = create_run!()
      pipeline = create_pipeline!(run)
      Pipeline.start!(pipeline)

      pipeline = Pipeline.complete_step!(pipeline, :create_revision)
      pipeline = Pipeline.complete_step!(pipeline, :load_packages)

      assert :create_revision in pipeline.completed_steps
      assert :load_packages in pipeline.completed_steps
      assert length(pipeline.completed_steps) == 2
    end

    test "completed_steps preserves existing entries on append" do
      run = create_run!()
      pipeline = create_pipeline!(run)
      Pipeline.start!(pipeline)

      pipeline = Pipeline.complete_step!(pipeline, :create_revision)
      pipeline = Pipeline.complete_step!(pipeline, :load_packages)
      pipeline = Pipeline.complete_step!(pipeline, :detect_package_events)

      assert pipeline.completed_steps == [
               :create_revision,
               :load_packages,
               :detect_package_events
             ]
    end

    test "does not duplicate already completed steps" do
      run = create_run!()
      pipeline = create_pipeline!(run)
      Pipeline.start!(pipeline)

      pipeline = Pipeline.complete_step!(pipeline, :create_revision)
      pipeline = Pipeline.complete_step!(pipeline, :create_revision)

      assert pipeline.completed_steps == [:create_revision]
    end
  end

  describe "start" do
    test "transitions from pending to running" do
      run = create_run!()
      pipeline = create_pipeline!(run)

      updated = Pipeline.start!(pipeline)

      assert updated.status == :running
    end
  end

  describe "mark_completed" do
    test "transitions to completed" do
      run = create_run!()
      pipeline = create_pipeline!(run) |> Pipeline.start!()

      updated = Pipeline.mark_completed!(pipeline)

      assert updated.status == :completed
    end
  end

  describe "mark_failed" do
    test "records failed step and error" do
      run = create_run!()
      pipeline = create_pipeline!(run) |> Pipeline.start!()

      updated = Pipeline.mark_failed!(pipeline, :load_packages, "something broke")

      assert updated.status == :failed
      assert updated.failed_step == :load_packages
      assert updated.error == "something broke"
    end
  end

  describe "retry_from_step" do
    test "clears failure state and sets status to running" do
      run = create_run!()

      pipeline =
        create_pipeline!(run)
        |> Pipeline.start!()
        |> Pipeline.mark_failed!(:load_packages, "timeout")

      updated = Pipeline.retry_from_step!(pipeline)

      assert updated.status == :running
      assert updated.failed_step == nil
      assert updated.error == nil
    end
  end

  describe "set_channel_revision_id" do
    test "sets the channel_revision_id" do
      run = create_run!()
      pipeline = create_pipeline!(run)

      updated = Pipeline.set_channel_revision_id!(pipeline, 42)

      assert updated.channel_revision_id == 42
    end
  end

  describe "find" do
    test "finds by channel and revision" do
      run = create_run!()
      create_pipeline!(run, %{channel: "nixos-unstable", revision: "abc123"})

      assert {:ok, pipeline} = Pipeline.find("nixos-unstable", "abc123")
      assert pipeline.channel == "nixos-unstable"
      assert pipeline.revision == "abc123"
    end

    test "returns error for non-existent" do
      assert {:error, _} = Pipeline.find("nonexistent", "nonexistent")
    end
  end

  describe "next_pending_for_channel" do
    test "returns pending pipelines ordered by sequence" do
      run = create_run!()
      create_pipeline!(run, %{revision: "rev3", sequence: 2})
      create_pipeline!(run, %{revision: "rev1", sequence: 0})
      create_pipeline!(run, %{revision: "rev2", sequence: 1})

      [first | _] = Pipeline.next_pending_for_channel!("nixos-unstable")

      assert first.revision == "rev1"
      assert first.sequence == 0
    end

    test "excludes non-pending pipelines" do
      run = create_run!()
      create_pipeline!(run, %{revision: "rev1", sequence: 0}) |> Pipeline.start!()
      create_pipeline!(run, %{revision: "rev2", sequence: 1})

      results = Pipeline.next_pending_for_channel!("nixos-unstable")

      assert length(results) == 1
      assert hd(results).revision == "rev2"
    end
  end

  describe "identity" do
    test "enforces unique channel+revision" do
      run = create_run!()
      create_pipeline!(run, %{channel: "nixos-unstable", revision: "abc123"})

      assert_raise Ash.Error.Invalid, fn ->
        create_pipeline!(run, %{channel: "nixos-unstable", revision: "abc123"})
      end
    end
  end
end

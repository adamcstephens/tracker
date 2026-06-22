defmodule Tracker.Ingestion.StepGraphTest do
  use ExUnit.Case, async: true

  alias Tracker.Ingestion.StepGraph

  describe "steps_for/1" do
    test "non-nixos channel gets base steps only" do
      steps = StepGraph.steps_for("nixpkgs-unstable")

      assert :create_revision in steps
      assert :load_packages in steps
      assert :finalize in steps
      refute :load_options in steps
      refute :link_options in steps
    end

    test "nixos channel gets options steps" do
      steps = StepGraph.steps_for("nixos-unstable")

      assert :create_revision in steps
      assert :load_packages in steps
      assert :finalize in steps
      assert :load_options in steps
      assert :link_options in steps
    end

    test "nixos-unstable-small gets options steps" do
      steps = StepGraph.steps_for("nixos-unstable-small")

      assert :load_options in steps
      assert :link_options in steps
    end
  end

  describe "ready_steps/2" do
    test "initially only create_revision is ready" do
      active = StepGraph.steps_for("nixos-unstable")
      completed = []

      assert StepGraph.ready_steps(active, completed) == [:create_revision]
    end

    test "after create_revision, load_packages and load_options are ready" do
      active = StepGraph.steps_for("nixos-unstable")
      completed = [:create_revision]

      ready = StepGraph.ready_steps(active, completed)

      assert :load_packages in ready
      assert :load_options in ready
      refute :finalize in ready
    end

    test "after load_packages alone, link_options is not yet ready" do
      active = StepGraph.steps_for("nixos-unstable")
      completed = [:create_revision, :load_packages]

      ready = StepGraph.ready_steps(active, completed)

      # link_options not yet ready — needs load_options too
      refute :link_options in ready
      assert :load_options in ready
    end

    test "link_options ready only when both load_packages and load_options complete" do
      active = StepGraph.steps_for("nixos-unstable")
      completed = [:create_revision, :load_packages, :load_options]

      ready = StepGraph.ready_steps(active, completed)

      assert :link_options in ready
    end

    test "finalize ready only when all other active steps complete" do
      active = StepGraph.steps_for("nixos-unstable")

      completed =
        active
        |> Enum.reject(&(&1 == :finalize))

      ready = StepGraph.ready_steps(active, completed)

      assert ready == [:finalize]
    end

    test "finalize not ready when any step incomplete" do
      active = StepGraph.steps_for("nixos-unstable")

      completed =
        active
        |> Enum.reject(&(&1 in [:finalize, :link_options]))

      ready = StepGraph.ready_steps(active, completed)

      refute :finalize in ready
      assert :link_options in ready
    end

    test "non-nixos channel: finalize ready after base steps" do
      active = StepGraph.steps_for("nixpkgs-unstable")
      completed = [:create_revision, :load_packages]

      ready = StepGraph.ready_steps(active, completed)

      assert ready == [:finalize]
    end

    test "skipped dependencies are treated as satisfied" do
      # If load_options is not in active_steps, link_options' dep on it is satisfied
      active = [:create_revision, :load_packages, :finalize]
      completed = [:create_revision]

      ready = StepGraph.ready_steps(active, completed)

      assert :load_packages in ready
      # link_options is not active, so not in ready
      refute :link_options in ready
    end

    test "already completed steps are not returned" do
      active = StepGraph.steps_for("nixpkgs-unstable")
      completed = [:create_revision]

      ready = StepGraph.ready_steps(active, completed)

      refute :create_revision in ready
    end

    test "empty active steps returns empty" do
      assert StepGraph.ready_steps([], []) == []
    end
  end

  describe "step_module/1" do
    test "returns module for each step" do
      assert StepGraph.step_module(:create_revision) == Tracker.Ingestion.Steps.CreateRevision
      assert StepGraph.step_module(:load_packages) == Tracker.Ingestion.Steps.LoadPackages
      assert StepGraph.step_module(:finalize) == Tracker.Ingestion.Steps.Finalize
    end

    test "raises for unknown step" do
      assert_raise KeyError, fn ->
        StepGraph.step_module(:nonexistent)
      end
    end
  end

  describe "metadata_channel/0" do
    test "returns the metadata channel name" do
      assert StepGraph.metadata_channel() == "nixos-unstable-small"
    end
  end
end

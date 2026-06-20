defmodule Tracker.Ingestion.StepGraph do
  @moduledoc """
  Encodes the DAG of ingestion step dependencies and computes
  which steps are ready to run given completed steps.

  The graph:

      create_revision ─┬─ load_packages ──┐
                       │              │   │
                       └─ load_options ┼── link_options
                       (nixos-* only)  │  └─ detect_option_events
                                       └─ finalize (all active done)

  Package added/removed/version-change events are derived from span boundaries
  on read, so there is no package-event detection step.
  """

  @metadata_channel "nixos-unstable-small"

  @graph %{
    create_revision: [],
    load_packages: [:create_revision],
    load_options: [:create_revision],
    link_options: [:load_packages, :load_options],
    detect_option_events: [:load_options],
    finalize: :all_active
  }

  @step_modules %{
    create_revision: Tracker.Ingestion.Steps.CreateRevision,
    load_packages: Tracker.Ingestion.Steps.LoadPackages,
    load_options: Tracker.Ingestion.Steps.LoadOptions,
    link_options: Tracker.Ingestion.Steps.LinkOptions,
    detect_option_events: Tracker.Ingestion.Steps.DetectOptionEvents,
    finalize: Tracker.Ingestion.Steps.Finalize
  }

  @doc """
  Returns the list of active steps for a given channel.

  All channels get: create_revision, load_packages, finalize.
  Channels starting with "nixos-" additionally get: load_options, link_options, detect_option_events.
  """
  @spec steps_for(String.t()) :: [atom()]
  def steps_for(channel) do
    base = [:create_revision, :load_packages, :finalize]

    if String.starts_with?(channel, "nixos-") do
      base ++ [:load_options, :link_options, :detect_option_events]
    else
      base
    end
  end

  @doc """
  Returns the step module for a given step name atom.
  """
  @spec step_module(atom()) :: module()
  def step_module(step) when is_atom(step) do
    Map.fetch!(@step_modules, step)
  end

  @doc """
  Returns the metadata channel name.
  """
  @spec metadata_channel() :: String.t()
  def metadata_channel, do: @metadata_channel

  @doc """
  Returns steps that are ready to run given the active and completed steps.

  A step is ready when:
  - It is in the active steps
  - It is not yet completed
  - All its dependencies are satisfied (completed OR not in active steps)

  The special `:all_active` dependency for finalize means it depends
  on all other active steps being completed.
  """
  @spec ready_steps([atom()], [atom()]) :: [atom()]
  def ready_steps(active_steps, completed_steps) do
    completed_set = MapSet.new(completed_steps)
    active_set = MapSet.new(active_steps)

    active_steps
    |> Enum.filter(fn step ->
      not MapSet.member?(completed_set, step) and
        deps_satisfied?(step, active_set, completed_set)
    end)
  end

  defp deps_satisfied?(step, active_set, completed_set) do
    case Map.fetch!(@graph, step) do
      :all_active ->
        active_set
        |> MapSet.delete(step)
        |> MapSet.subset?(completed_set)

      deps ->
        Enum.all?(deps, fn dep ->
          MapSet.member?(completed_set, dep) or not MapSet.member?(active_set, dep)
        end)
    end
  end
end

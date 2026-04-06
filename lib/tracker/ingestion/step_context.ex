defmodule Tracker.Ingestion.StepContext do
  @moduledoc """
  Context passed to each step's `run/1` callback.

  Contains the pipeline record and optionally the channel revision
  (loaded when `pipeline.channel_revision_id` is set).
  """
  use TypedStruct

  typedstruct enforce: true do
    field :pipeline, Tracker.Ingestion.Pipeline.t()
    field :channel_revision, Tracker.Nixpkgs.ChannelRevision.t(), enforce: false
  end
end

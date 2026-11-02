defmodule Tracker.Ingestion.Steps.Finalize do
  @moduledoc """
  Persists predecessor comparison summaries, then records success and broadcasts completion.

  Sets `result: :success` on the channel revision. For nixos-* channels
  where options were loaded, also sets `options_result: :success`.
  """

  @behaviour Tracker.Ingestion.Step

  alias Tracker.Ingestion.StepContext
  alias Tracker.Nixpkgs.{ChannelRevision, RevisionSummary}

  @impl Tracker.Ingestion.Step
  def timeout, do: :timer.minutes(15)

  @impl Tracker.Ingestion.Step
  def run(%StepContext{} = context) do
    options_loaded? = :load_options in context.pipeline.active_steps
    completed_revision = %{context.channel_revision | result: :success}

    completed_revision =
      if options_loaded?,
        do: %{completed_revision | options_result: :success},
        else: completed_revision

    with {:ok, revision} <- RevisionSummary.persist(context.channel_revision, completed_revision) do
      revision = ChannelRevision.record_result!(revision, %{result: :success})

      if options_loaded? do
        ChannelRevision.record_options_result!(revision, %{options_result: :success})
      end

      :ok
    else
      {:error, error} -> {:error, error}
    end
  end
end

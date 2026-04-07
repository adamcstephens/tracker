defmodule Tracker.Ingestion.Steps.Finalize do
  @moduledoc """
  Records success on the ChannelRevision and broadcasts completion.

  Sets `result: :success` on the channel revision. For nixos-* channels
  where options were loaded, also sets `options_result: :success`.
  """

  @behaviour Tracker.Ingestion.Step

  @impl true
  def timeout, do: :timer.seconds(30)

  @impl true
  def run(%Tracker.Ingestion.StepContext{pipeline: pipeline, channel_revision: channel_revision}) do
    Tracker.Nixpkgs.ChannelRevision.record_result!(channel_revision, %{result: :success})

    if :load_options in pipeline.active_steps do
      Tracker.Nixpkgs.ChannelRevision.record_options_result!(channel_revision, %{
        options_result: :success
      })
    end

    channel = Ash.get!(Tracker.Nixpkgs.Channel, pipeline.channel_id)

    Phoenix.PubSub.broadcast(
      Tracker.PubSub,
      "channel_revisions:#{channel.name}",
      {:channel_revision_completed, %{channel_name: channel.name, revision: pipeline.revision}}
    )

    :ok
  end
end

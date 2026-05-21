defmodule Tracker.Ingestion.Steps.CreateRevision do
  @moduledoc """
  Creates a ChannelRevision record and links it to the pipeline.

  Looks up the previous revision for the same channel to establish
  the revision chain used by event detection steps.
  """

  @behaviour Tracker.Ingestion.Step

  alias Tracker.Nixpkgs.{
    ChangeBranchDetectionWorker,
    ChannelRevision,
    ChannelRevisionLinkWorker,
    ReleaseCache
  }

  alias Tracker.Ingestion.Helpers

  @impl true
  def timeout, do: :timer.seconds(30)

  @impl true
  def run(%Tracker.Ingestion.StepContext{pipeline: pipeline}) do
    previous_revision = find_previous_revision(pipeline.channel_id, pipeline.revision)

    create_attrs =
      %{
        revision: pipeline.revision,
        channel_id: pipeline.channel_id,
        released_at: pipeline.released_at
      }
      |> Helpers.maybe_put(
        :previous_channel_revision_id,
        previous_revision && previous_revision.id
      )

    channel_revision = ChannelRevision.create!(create_attrs)

    Tracker.Ingestion.Pipeline.set_channel_revision_id!(pipeline, channel_revision.id)

    %{} |> ChangeBranchDetectionWorker.new() |> Oban.insert!()

    %{channel_revision_id: channel_revision.id}
    |> ChannelRevisionLinkWorker.new()
    |> Oban.insert!()

    :ok
  end

  defp find_previous_revision(channel_id, revision) do
    channel = Ash.get!(Tracker.Nixpkgs.Channel, channel_id)

    case ReleaseCache.find_previous_release(channel.name, revision) do
      %ReleaseCache.Release{revision: prev_revision} when is_binary(prev_revision) ->
        case ChannelRevision.find(channel_id, prev_revision) do
          {:ok, rev} -> rev
          _ -> nil
        end

      _ ->
        nil
    end
  end
end

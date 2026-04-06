defmodule Tracker.Ingestion.Steps.DetectOptionEvents do
  @moduledoc """
  Diffs option revisions between the current and previous channel
  revision to detect added and removed options.

  Deletes any existing events for this channel revision first
  to ensure idempotency on retry.
  """

  @behaviour Tracker.Ingestion.Step

  import Ecto.Query

  @impl true
  def timeout, do: :timer.minutes(5)

  @impl true
  def run(%Tracker.Ingestion.StepContext{channel_revision: channel_revision}) do
    if is_nil(channel_revision.previous_channel_revision_id) do
      :ok
    else
      # Delete existing events for idempotency
      from(oe in "option_events", where: oe.channel_revision_id == ^channel_revision.id)
      |> Tracker.Repo.delete_all()

      {added, removed} =
        Tracker.Nixpkgs.OptionRevision.diff_option_ids(
          channel_revision.id,
          channel_revision.previous_channel_revision_id
        )

      events =
        Enum.map(added, fn option_id ->
          %{type: :added, option_id: option_id, channel_revision_id: channel_revision.id}
        end) ++
          Enum.map(removed, fn option_id ->
            %{type: :removed, option_id: option_id, channel_revision_id: channel_revision.id}
          end)

      Tracker.Nixpkgs.OptionEvent.bulk_create_all(events)

      :ok
    end
  end
end

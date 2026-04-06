defmodule Tracker.Ingestion.Steps.DetectPackageEvents do
  @moduledoc """
  Diffs package revisions between the current and previous channel
  revision to detect added and removed packages.

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
      from(pe in "package_events", where: pe.channel_revision_id == ^channel_revision.id)
      |> Tracker.Repo.delete_all()

      {added, removed} =
        Tracker.Nixpkgs.PackageRevision.diff_package_ids(
          channel_revision.id,
          channel_revision.previous_channel_revision_id
        )

      events =
        Enum.map(added, fn package_id ->
          %{type: :added, package_id: package_id, channel_revision_id: channel_revision.id}
        end) ++
          Enum.map(removed, fn package_id ->
            %{type: :removed, package_id: package_id, channel_revision_id: channel_revision.id}
          end)

      Tracker.Nixpkgs.PackageEvent.bulk_create_all(events)

      :ok
    end
  end
end

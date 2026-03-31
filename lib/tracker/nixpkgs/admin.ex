defmodule Tracker.Nixpkgs.Admin do
  @moduledoc """
  Administrative repair tools for channel revision data.
  """

  require Logger

  alias Tracker.Nixpkgs.{ChannelRevision, ChannelWorker, ReleaseCache}

  @doc """
  Repairs a broken channel revision and its successor.

  A "broken" revision is one that was partially written (e.g. result is nil,
  no package_revisions). This corrupts the next revision's events because it
  diffs against an empty set.

  This function:
  1. Finds the broken revision and the one after it
  2. Deletes both (channel_revisions, package_revisions, package_events)
  3. Replays both via `ChannelWorker.fetch_channel/3` + `write_to_database/1`
  4. Updates the revision after the pair to point to the newly replayed successor

  `write_to_database/1` determines `previous_channel_revision_id` via the
  release cache, so the replayed revisions will chain correctly as long as
  they are replayed in chronological order.

  ## Examples

      Admin.repair_revision("nixos-25.11", "71caefc")
  """
  def repair_revision(channel, revision_prefix) do
    broken = ChannelRevision.find_by_short_hash!(channel, revision_prefix)
    Logger.info("Found broken revision: id=#{broken.id} revision=#{broken.revision}")

    next = find_next_revision(broken.id)

    if is_nil(next) do
      Logger.info("No successor revision found, only repairing the broken one")
    else
      Logger.info("Found successor revision: id=#{next.id} revision=#{next.revision}")
    end

    # Gather releases before deleting anything
    revisions_to_replay = [broken | List.wrap(next)]
    after_last = if next, do: find_next_revision(next.id)

    releases =
      Map.new(revisions_to_replay, fn rev ->
        {rev.revision, find_release!(channel, rev.revision)}
      end)

    # Delete in reverse chain order (next references broken)
    for rev <- Enum.reverse(revisions_to_replay) do
      delete_revision!(rev.id)
      Logger.info("Deleted revision #{rev.id} (#{String.slice(rev.revision, 0, 12)})")
    end

    # Replay in chronological order
    new_revisions =
      Enum.map(revisions_to_replay, fn rev ->
        release = Map.fetch!(releases, rev.revision)

        ChannelWorker.fetch_channel(channel, rev.revision, release.base_url)
        |> Map.put("released_at", release.released_at)
        |> ChannelWorker.write_to_database()

        {:ok, new_rev} = ChannelRevision.find(channel, rev.revision)
        Logger.info("Replayed revision #{new_rev.id} (#{String.slice(rev.revision, 0, 12)})")
        new_rev
      end)

    # Update the revision after the replayed pair to point to the new last one
    if after_last do
      new_last = List.last(new_revisions)
      update_previous_pointer!(after_last.id, new_last.id)

      Logger.info("Updated revision #{after_last.id} to point to new predecessor #{new_last.id}")
    end

    :ok
  end

  defp find_next_revision(revision_id) do
    case Tracker.Repo.query!(
           "SELECT id FROM channel_revisions WHERE previous_channel_revision_id = $1 LIMIT 1",
           [revision_id]
         ) do
      %{rows: [[id]]} ->
        Ash.get!(ChannelRevision, id)

      %{rows: []} ->
        nil
    end
  end

  defp find_release!(channel, revision) do
    releases = ReleaseCache.get_releases(channel) |> Enum.reverse()

    Enum.find(releases, fn r -> String.starts_with?(revision, r.short_hash) end) ||
      raise "Release not found in cache for revision #{revision} on channel #{channel}"
  end

  defp delete_revision!(id) do
    Tracker.Repo.query!("DELETE FROM package_events WHERE channel_revision_id = $1", [id])
    Tracker.Repo.query!("DELETE FROM package_revisions WHERE channel_revision_id = $1", [id])
    Tracker.Repo.query!("DELETE FROM channel_revisions WHERE id = $1", [id])
  end

  defp update_previous_pointer!(revision_id, previous_id) do
    Tracker.Repo.query!(
      "UPDATE channel_revisions SET previous_channel_revision_id = $1 WHERE id = $2",
      [previous_id, revision_id]
    )
  end
end

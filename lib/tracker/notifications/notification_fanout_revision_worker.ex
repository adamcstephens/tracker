defmodule Tracker.Notifications.NotificationFanoutRevisionWorker do
  @moduledoc """
  Fans out notifications for a completed `ChannelRevision`.

  Enqueued from an after-transaction hook on `ChannelRevision.record_result`
  when the build result is `:success` (never via PubSub). Two set-based
  queries, not a per-subscriber loop:

    * channel subscriptions to the revision's channel →
      `:channel_revision_published`.
    * package subscriptions whose channel scope includes this channel, joined
      against the revision's changed packages (added/removed from
      `PackageEvent`, version changes from `PackageRevision`) →
      `:package_added` / `:package_removed` / `:package_version_changed`.

  Every row carries a unique `dedup_key`, so retries and reconciliation
  reruns are no-ops.
  """

  use Oban.Worker,
    queue: :ingestion,
    max_attempts: 5,
    unique: [period: 60, keys: [:channel_revision_id]]

  alias Tracker.Nixpkgs.{ChannelRevision, PackageEvent, PackageRevision}
  alias Tracker.Notifications.{ChannelSubscription, Notification, PackageSubscription}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"channel_revision_id" => id}}) do
    run(channel_revision_id: id)
  end

  @doc "Runs the fan-out for `:channel_revision_id`."
  def run(opts) do
    id = Keyword.fetch!(opts, :channel_revision_id)
    revision = Ash.get!(ChannelRevision, id, authorize?: false)

    Notification.fanout(channel_rows(revision) ++ package_rows(revision))
  end

  defp channel_rows(revision) do
    revision.channel_id
    |> ChannelSubscription.subscribers_of_channel!(authorize?: false)
    |> Enum.map(fn sub ->
      %{
        user_id: sub.user_id,
        type: :channel_revision_published,
        channel_id: revision.channel_id,
        channel_revision_id: revision.id,
        occurred_at: revision.released_at,
        dedup_key: "chansub:#{sub.id}:cr:#{revision.id}"
      }
    end)
  end

  # The first revision of a channel has no predecessor to diff against.
  defp package_rows(%{previous_channel_revision_id: nil}), do: []

  defp package_rows(revision) do
    subs =
      PackageSubscription.subscribers_in_channel_scope!(revision.channel_id, authorize?: false)

    case subs |> Enum.map(& &1.package_id) |> Enum.uniq() do
      [] ->
        []

      package_ids ->
        type_map = changed_package_types(revision, package_ids)

        for sub <- subs, type = Map.get(type_map, sub.package_id), not is_nil(type) do
          %{
            user_id: sub.user_id,
            type: type,
            package_id: sub.package_id,
            channel_id: revision.channel_id,
            channel_revision_id: revision.id,
            occurred_at: revision.released_at,
            dedup_key: "pkgsub:#{sub.id}:cr:#{revision.id}:pkg:#{sub.package_id}"
          }
        end
    end
  end

  # %{package_id => :package_added | :package_removed | :package_version_changed}
  defp changed_package_types(revision, package_ids) do
    event_map =
      revision.id
      |> PackageEvent.list_for_revision_packages!(package_ids, authorize?: false)
      |> Map.new(fn
        %{type: :added, package_id: pid} -> {pid, :package_added}
        %{type: :removed, package_id: pid} -> {pid, :package_removed}
      end)

    remaining = package_ids -- Map.keys(event_map)

    revision
    |> version_changed_ids(remaining)
    |> Enum.reduce(event_map, fn pid, acc -> Map.put(acc, pid, :package_version_changed) end)
  end

  defp version_changed_ids(_revision, []), do: []

  defp version_changed_ids(revision, package_ids) do
    prev_id = revision.previous_channel_revision_id

    [revision.id, prev_id]
    |> PackageRevision.for_revisions_packages!(package_ids, authorize?: false)
    |> Enum.group_by(& &1.package_id)
    |> Enum.filter(fn {_pid, revs} ->
      new_v = version_at(revs, revision.id)
      old_v = version_at(revs, prev_id)
      not is_nil(new_v) and not is_nil(old_v) and new_v != old_v
    end)
    |> Enum.map(fn {pid, _revs} -> pid end)
  end

  defp version_at(revs, channel_revision_id) do
    Enum.find_value(revs, fn r ->
      if r.channel_revision_id == channel_revision_id, do: r.version
    end)
  end
end

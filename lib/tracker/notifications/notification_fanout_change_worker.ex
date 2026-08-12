defmodule Tracker.Notifications.NotificationFanoutChangeWorker do
  @moduledoc """
  Fans out notifications for the packages a `Change` touches.

  Enqueued from `ChangeArtifactRefreshWorker` once the `ChangePackage` link
  set has been written — at discovery time a change has no package links yet,
  so this is the earliest point the impacted packages are known.

  The change's state picks the event: `:draft`/`:open` →
  `:package_change_opened`, `:merged` → `:package_change_merged`. A
  subscription is notified when it selected that event and its channel scope
  covers the change: an all-channels subscription always matches, while a
  channel-scoped one matches when the change's `base_ref` propagates into that
  channel. Backports target `release-X.Y` directly, so a subscription scoped to
  the matching stable channel picks them up while master PRs pass it by.

  Every row carries a unique `dedup_key`, so the repeated artifact refreshes an
  open change goes through are no-ops while its later merge still notifies.
  """

  use Oban.Worker,
    queue: :changes,
    max_attempts: 5,
    unique: [period: 60, keys: [:change_id]]

  alias Tracker.Nixpkgs.{Change, ChangePackage, Propagation}
  alias Tracker.Notifications.{Notification, PackageSubscription}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"change_id" => id}}) do
    run(change_id: id)
  end

  @doc "Runs the fan-out for `:change_id`."
  def run(opts) do
    id = Keyword.fetch!(opts, :change_id)
    change = Ash.get!(Change, id, authorize?: false)

    Notification.fanout(rows(change, event_for(change.state)))
  end

  defp event_for(state) when state in [:draft, :open], do: :package_change_opened
  defp event_for(:merged), do: :package_change_merged
  defp event_for(_state), do: nil

  defp rows(_change, nil), do: []

  defp rows(change, event) do
    case ChangePackage.for_change!(change.id, authorize?: false) do
      [] ->
        []

      links ->
        package_ids = Enum.map(links, & &1.package_id)
        channels = reachable_channels(change.base_ref)
        occurred_at = occurred_at(change, event)

        package_ids
        |> PackageSubscription.subscribers_of_packages!(authorize?: false)
        |> Enum.filter(&(event in &1.events and in_scope?(&1, channels)))
        |> Enum.map(fn sub ->
          %{
            user_id: sub.user_id,
            type: event,
            package_id: sub.package_id,
            channel_id: sub.channel_id,
            change_id: change.id,
            occurred_at: occurred_at,
            dedup_key: "pkgsub:#{sub.id}:chg:#{change.id}:#{event}"
          }
        end)
    end
  end

  defp occurred_at(change, :package_change_merged), do: change.merged_at
  defp occurred_at(change, :package_change_opened), do: change.gh_created_at

  defp reachable_channels(nil), do: []
  defp reachable_channels(base_ref), do: Propagation.terminal_channels(base_ref)

  defp in_scope?(%{channel_id: nil}, _channels), do: true
  defp in_scope?(sub, channels), do: sub.channel.name in channels
end

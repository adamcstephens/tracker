defmodule Tracker.Notifications.NotificationFanoutPropagationWorker do
  @moduledoc """
  Fans out `:change_propagated` notifications for a `ChangeBranch`.

  Enqueued from an after-transaction hook on `ChangeBranch.create` (never via
  PubSub). Any-branch change subscriptions (nil channel) always match; a
  channel-targeted subscription matches when the branch maps to that channel
  via its linked `channel_revision.channel_id`. Because `ChangeBranch.create`
  upserts the `channel_revision_id` in later passes, the worker may run again
  with a mapped channel — already-notified subscriptions are no-ops on their
  `dedup_key`.
  """

  use Oban.Worker,
    queue: :changes,
    max_attempts: 5,
    unique: [period: 60, keys: [:change_branch_id]]

  alias Tracker.Nixpkgs.ChangeBranch
  alias Tracker.Notifications.{ChangeSubscription, Notification}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"change_branch_id" => id}}) do
    run(change_branch_id: id)
  end

  @doc "Runs the fan-out for `:change_branch_id`."
  def run(opts) do
    id = Keyword.fetch!(opts, :change_branch_id)
    branch = Ash.get!(ChangeBranch, id, load: [:channel_revision], authorize?: false)

    mapped_channel_id = branch.channel_revision && branch.channel_revision.channel_id

    occurred_at =
      (branch.channel_revision && branch.channel_revision.released_at) ||
        DateTime.utc_now(:second)

    rows =
      branch.change_id
      |> ChangeSubscription.subscribers_of_change!(mapped_channel_id, authorize?: false)
      |> Enum.map(fn sub ->
        %{
          user_id: sub.user_id,
          type: :change_propagated,
          change_id: branch.change_id,
          change_branch_id: branch.id,
          channel_id: mapped_channel_id,
          channel_revision_id: branch.channel_revision_id,
          occurred_at: occurred_at,
          dedup_key: "changesub:#{sub.id}:cb:#{branch.id}"
        }
      end)

    Notification.fanout(rows)
  end
end

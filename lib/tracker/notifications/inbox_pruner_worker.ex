defmodule Tracker.Notifications.InboxPrunerWorker do
  use Oban.Worker, queue: :changes, max_attempts: 3

  require Ash.Query

  alias Tracker.Notifications.Notification

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: run(DateTime.utc_now(:second))

  def run(%DateTime{} = now) do
    cutoff = DateTime.add(now, -180, :day)

    Notification
    |> Ash.Query.filter(occurred_at < ^cutoff)
    |> Ash.bulk_destroy!(:destroy, %{},
      strategy: :atomic,
      authorize?: false,
      return_errors?: true
    )

    :ok
  end
end

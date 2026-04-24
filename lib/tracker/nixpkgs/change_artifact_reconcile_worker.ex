defmodule Tracker.Nixpkgs.ChangeArtifactReconcileWorker do
  @moduledoc """
  Drains the backlog of merged Changes whose artifacts haven't been
  processed yet.

  Catches the case where a PR merged faster than discovery could see it
  as open/draft first — the row is upserted already in state `:merged`,
  no transition fires in `ChangeRefreshWorker`, and nothing enqueues the
  artifact refresh. This worker periodically selects such rows and
  enqueues `ChangeArtifactRefreshWorker(reason: "merged")` for each,
  relying on Oban uniqueness to deduplicate.
  """
  use Oban.Worker, queue: :changes, max_attempts: 3

  require Logger

  alias Tracker.Nixpkgs.Change
  alias Tracker.Nixpkgs.ChangeArtifactRefreshWorker

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: run()

  @doc """
  Selects pending-merged Changes and enqueues a refresh for each.
  Returns `{:ok, enqueued_count}`.
  """
  def run do
    backlog = Change.pending_merged_backlog!()

    Enum.each(backlog, fn change ->
      %{"number" => change.number, "reason" => "merged"}
      |> ChangeArtifactRefreshWorker.new()
      |> Oban.insert!()
    end)

    count = length(backlog)

    if count > 0 do
      Logger.info(msg: "reconcile enqueued merged-pending refreshes", count: count)
    end

    {:ok, count}
  end
end

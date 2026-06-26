defmodule Tracker.Nixpkgs.ChannelRevisionLinkWorker do
  @moduledoc """
  Links merged Changes to the specific `ChannelRevision` that first
  carried them.

  Enqueued per-`ChannelRevision` from
  `Tracker.Ingestion.Steps.CreateRevision`. Owns all `ChangeBranch`
  rows for channel-kind branches (`nixos-*`, `nixpkgs-*`); intermediate
  branches are handled by
  `Tracker.Nixpkgs.ChangeBranchDetectionWorker`.

  ## Invariant

  `change_branches.channel_revision_id` is the smallest
  `ChannelRevision` (by `released_at`, for the channel matching
  `branch_name`) whose `revision` sha has the Change's
  `merge_commit_sha` as an ancestor. This is a property of git history
  plus the `channel_revisions` table alone — independent of when this
  worker ran.

  ## Algorithm

  For each candidate Change (merged, with `merge_commit_sha`, no
  `ChangeBranch` row for this branch with a non-nil
  `channel_revision_id`):

  1.  Check ancestor against `R_n` (the triggering revision). If
      false, skip — the change isn't in this channel yet.
  2.  Check ancestor against `R_{n-1}` (previous revision). If false
      or nil, the change first landed in `R_n` — link and stop.
  3.  Otherwise the change was already in `R_{n-1}` (late detection /
      back-fill). Bisect over the channel's revisions ordered
      ascending by `released_at` to find the smallest containing one.

  Steady-state cost is two ancestor checks per change. Bisection
  (step 3) is O(log n) and only fires when this worker missed an
  earlier window.
  """

  use Oban.Worker,
    queue: :revision_link,
    max_attempts: 5,
    unique: [period: 60, keys: [:channel_revision_id]]

  require Logger

  alias Tracker.GitServer
  alias Tracker.Nixpkgs.Change
  alias Tracker.Nixpkgs.ChangeBranch
  alias Tracker.Nixpkgs.ChannelRevision
  alias Tracker.Nixpkgs.Propagation

  @max_concurrency 8
  @ancestor_timeout :timer.seconds(30)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"channel_revision_id" => id}}) do
    run(channel_revision_id: id)
  end

  @doc """
  Runs the link pass for `channel_revision_id`.

  Options:
    * `:channel_revision_id` — required.
    * `:git_server` — `GenServer.server()` for the `GitServer` instance
      (defaults to the named `Tracker.GitServer`).
  """
  def run(opts) do
    channel_revision_id = Keyword.fetch!(opts, :channel_revision_id)
    git_server = Keyword.get(opts, :git_server, Tracker.GitServer)

    Logger.info(
      msg: "channel revision link started",
      channel_revision_id: channel_revision_id
    )

    started_at = System.monotonic_time()
    snapshot = GitServer.state(git_server)

    if snapshot.ready do
      r_n =
        Ash.get!(ChannelRevision, channel_revision_id,
          load: [:channel, :previous_channel_revision]
        )

      branch_name = r_n.channel.name

      if Propagation.valid_branch?(branch_name) and Propagation.kind(branch_name) == :channel do
        candidates = Change.for_channel_link!(branch_name)

        recorded =
          candidates
          |> Task.async_stream(
            fn change -> link_change(change, r_n, branch_name, snapshot) end,
            max_concurrency: @max_concurrency,
            timeout: @ancestor_timeout,
            on_timeout: :kill_task
          )
          |> Enum.count(&match?({:ok, {:recorded, _}}, &1))

        Logger.info(
          msg: "channel revision link finished",
          outcome: :ok,
          channel_revision_id: channel_revision_id,
          branch_name: branch_name,
          candidates: length(candidates),
          recorded: recorded,
          duration_ms: duration_ms(started_at)
        )

        :ok
      else
        Logger.warning(
          msg: "ChannelRevisionLinkWorker: channel name is not a propagation channel",
          channel_revision_id: channel_revision_id,
          branch_name: branch_name
        )

        Logger.info(
          msg: "channel revision link finished",
          outcome: :skipped,
          channel_revision_id: channel_revision_id,
          branch_name: branch_name,
          duration_ms: duration_ms(started_at)
        )

        :ok
      end
    else
      Logger.warning(msg: "ChannelRevisionLinkWorker: GitServer not ready, snoozing")

      Logger.info(
        msg: "channel revision link finished",
        outcome: :snoozed,
        channel_revision_id: channel_revision_id,
        snooze_seconds: 30,
        duration_ms: duration_ms(started_at)
      )

      {:snooze, 30}
    end
  end

  defp duration_ms(started_at) do
    System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)
  end

  defp link_change(change, r_n, branch_name, snapshot) do
    case GitServer.ancestor?(change.merge_commit_sha, r_n.revision, snapshot) do
      {:ok, false} ->
        :no_match

      {:ok, true} ->
        link_within_or_bisect(change, r_n, branch_name, snapshot)

      {:error, reason} ->
        log_ancestor_error(change, r_n.revision, reason)
        :error
    end
  end

  defp link_within_or_bisect(change, r_n, branch_name, snapshot) do
    case r_n.previous_channel_revision do
      nil ->
        record(change, branch_name, r_n.id)

      prev ->
        case GitServer.ancestor?(change.merge_commit_sha, prev.revision, snapshot) do
          {:ok, false} ->
            record(change, branch_name, r_n.id)

          {:ok, true} ->
            bisect_and_record(change, r_n, branch_name, snapshot)

          {:error, reason} ->
            log_ancestor_error(change, prev.revision, reason)
            :error
        end
    end
  end

  defp bisect_and_record(change, r_n, branch_name, snapshot) do
    revisions = ChannelRevision.by_channel_asc!(r_n.channel_id)

    case find_first_ancestor(revisions, change.merge_commit_sha, snapshot) do
      {:ok, rev} ->
        record(change, branch_name, rev.id)

      {:error, reason} ->
        log_ancestor_error(change, "bisect", reason)
        :error
    end
  end

  defp find_first_ancestor(revisions, sha, snapshot) do
    arr = List.to_tuple(revisions)
    bisect(arr, sha, snapshot, 0, tuple_size(arr) - 1)
  end

  defp bisect(arr, _sha, _snapshot, lo, hi) when lo == hi do
    {:ok, elem(arr, lo)}
  end

  defp bisect(arr, sha, snapshot, lo, hi) do
    mid = div(lo + hi, 2)
    rev = elem(arr, mid)

    case GitServer.ancestor?(sha, rev.revision, snapshot) do
      {:ok, true} -> bisect(arr, sha, snapshot, lo, mid)
      {:ok, false} -> bisect(arr, sha, snapshot, mid + 1, hi)
      {:error, _} = err -> err
    end
  end

  defp record(change, branch_name, channel_revision_id) do
    ChangeBranch.create!(%{
      change_id: change.id,
      branch_name: branch_name,
      channel_revision_id: channel_revision_id
    })

    {:recorded, channel_revision_id}
  end

  defp log_ancestor_error(change, ref, reason) do
    Logger.warning(
      msg: "ChannelRevisionLinkWorker: ancestor check failed",
      change_number: change.number,
      ref: ref,
      reason: inspect(reason)
    )
  end
end

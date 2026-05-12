defmodule Tracker.Nixpkgs.ChangeTransitions do
  @moduledoc """
  Detects lifecycle transitions on a `Tracker.Nixpkgs.Change` and emits the
  associated downstream side effects (artifact refresh enqueues, ChangeBranch
  seeding, ChangePackage clearing).

  Used by both `ChangeRefreshWorker` (per-record polling) and
  `ChangeDiscoveryWorker` (bulk upsert diff) so that transitions are
  handled identically regardless of which worker observed them first.
  """

  require Logger

  alias Tracker.GitHub.GraphQL.PullRequest
  alias Tracker.Nixpkgs.Change
  alias Tracker.Nixpkgs.ChangeArtifactRefreshWorker
  alias Tracker.Nixpkgs.ChangeBranch
  alias Tracker.Nixpkgs.ChangePackage

  @type transition :: :merged | :head_sha_changed | :closed_no_merge

  @doc """
  Returns the list of transitions implied by going from `prior` to `pr`.

  `prior` is any struct/map exposing `:state` and `:head_sha`. `pr` is a
  `Tracker.GitHub.GraphQL.PullRequest`.
  """
  @spec detect(map(), PullRequest.t()) :: [transition()]
  def detect(%{state: prior_state, head_sha: prior_sha}, %PullRequest{} = pr) do
    []
    |> maybe_add(prior_state != :merged and pr.state == :merged, :merged)
    |> maybe_add(
      pr.state in [:open, :draft] and prior_sha != pr.head_sha,
      :head_sha_changed
    )
    |> maybe_add(
      prior_state in [:open, :draft] and pr.state == :closed and is_nil(pr.merged_at),
      :closed_no_merge
    )
  end

  defp maybe_add(list, true, tag), do: [tag | list]
  defp maybe_add(list, false, _), do: list

  @doc """
  Default transition handler. Emits the side effects associated with a
  transition: artifact-refresh enqueue for :merged / :head_sha_changed,
  ChangeBranch seeding on :merged, ChangePackage clearing on :closed_no_merge.
  """
  @spec emit(Change.t(), transition()) :: :ok
  def emit(change, reason) when reason in [:merged, :head_sha_changed] do
    Logger.info(
      msg: "artifact_refresh transition detected",
      number: change.number,
      node_id: change.node_id,
      reason: reason
    )

    %{"number" => change.number, "reason" => Atom.to_string(reason)}
    |> ChangeArtifactRefreshWorker.new()
    |> Oban.insert!()

    if reason == :merged, do: ChangeBranch.seed_for_base_ref(change.id, change.base_ref)

    :ok
  end

  def emit(change, :closed_no_merge) do
    Logger.info(
      msg: "clearing ChangePackage links for closed-without-merge PR",
      number: change.number,
      node_id: change.node_id
    )

    {:ok, notifications} =
      Tracker.Repo.transaction(fn ->
        ChangePackage.clear_for_change!(change.id)

        {_, notifications} =
          Change.update_package_count!(
            change,
            %{package_count: 0},
            return_notifications?: true
          )

        notifications
      end)

    Ash.Notifier.notify(notifications)
    :ok
  end
end

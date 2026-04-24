defmodule Tracker.Nixpkgs.ChangeArtifactRefreshWorker do
  @moduledoc """
  Refreshes the ChangePackage link set for a Change from its latest
  comparison artifact, atomically replacing the existing links.

  Currently only the `"merged"` reason is implemented (pulls from the
  Merge Group workflow run keyed by `merge_commit_sha`). trk-185 will
  add the `"head_sha_changed"` path for open/draft PRs.
  """
  use Oban.Worker, queue: :changes, max_attempts: 10

  require Logger

  alias Tracker.GitHub.RateLimitCache
  alias Tracker.Nixpkgs.Change
  alias Tracker.Nixpkgs.ChangeArtifactCache
  alias Tracker.Nixpkgs.ChangePackage
  alias Tracker.Nixpkgs.Package

  @repo "NixOS/nixpkgs"
  @link_cap 1000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"number" => number, "reason" => reason}}) do
    run(%{number: number, reason: reason})
  end

  @doc """
  Entry point for the refresh flow. Accepts `:attrdiff_fetcher` and
  `:rate_limit_table` options for test injection.
  """
  def run(args, opts \\ [])

  def run(%{reason: "merged", number: number}, opts) do
    table = Keyword.get(opts, :rate_limit_table, RateLimitCache)

    case RateLimitCache.check(:rest, table) do
      {:limited, seconds} ->
        Logger.info("REST rate limited for #{seconds}s, snoozing artifact refresh")
        {:snooze, seconds}

      :ok ->
        do_run_merged(number, opts)
    end
  end

  def run(%{reason: reason, number: number}, _opts) do
    Logger.info(
      msg: "ChangeArtifactRefreshWorker: reason not yet implemented",
      number: number,
      reason: reason
    )

    :ok
  end

  defp do_run_merged(number, opts) do
    case Change.get_by_number(number) do
      {:ok, change} ->
        fetcher = Keyword.get_lazy(opts, :attrdiff_fetcher, fn -> &default_fetcher/1 end)

        case fetcher.(change) do
          {:ok, attrdiff} ->
            apply_refresh(change, attrdiff)

          {:snooze, _} = snooze ->
            snooze

          {:error, :rate_limited} ->
            snooze = snooze_seconds_for(:rest)
            Logger.warning("Artifact refresh rate limited, snoozing #{snooze}s")
            {:snooze, snooze}

          {:error, :artifact_expired} ->
            Change.update_processing_status!(change, %{processing_status: :artifact_expired})
            Logger.warning(msg: "artifact expired", number: number)
            :ok

          {:error, reason} ->
            Logger.error(
              msg: "ChangeArtifactRefreshWorker fetch failed",
              number: number,
              reason: inspect(reason)
            )

            Change.update_processing_status!(change, %{processing_status: :failed})
            {:error, reason}
        end

      _ ->
        Logger.warning(msg: "ChangeArtifactRefreshWorker: change not found", number: number)
        :ok
    end
  end

  defp apply_refresh(change, attrdiff) do
    typed_entries = flatten_attrdiff(attrdiff)
    total = length(typed_entries)

    if total > @link_cap do
      Logger.warning(
        msg: "link cap exceeded, marking too_large",
        number: change.number,
        total: total,
        cap: @link_cap
      )

      {:ok, notifications} =
        Tracker.Repo.transaction(fn ->
          ChangePackage.clear_for_change!(change.id)

          {_, n1} =
            Change.update_processing_status!(
              change,
              %{processing_status: :too_large},
              return_notifications?: true
            )

          {_, n2} =
            Change.update_package_count!(
              change,
              %{package_count: total},
              return_notifications?: true
            )

          n1 ++ n2
        end)

      Ash.Notifier.notify(notifications)
      :ok
    else
      all_attrs = Enum.map(typed_entries, &elem(&1, 1))
      ensure_packages_exist(all_attrs)
      id_map = package_id_map(all_attrs)

      records =
        Enum.map(typed_entries, fn {type, attr} ->
          %{change_id: change.id, package_id: id_map[attr], type: type}
        end)

      {:ok, notifications} =
        Tracker.Repo.transaction(fn ->
          ChangePackage.clear_for_change!(change.id)
          ChangePackage.bulk_create_all(records)

          {_, n1} =
            Change.update_processing_status!(
              change,
              %{processing_status: :processed},
              return_notifications?: true
            )

          {_, n2} =
            Change.update_package_count!(
              change,
              %{package_count: total},
              return_notifications?: true
            )

          n1 ++ n2
        end)

      Ash.Notifier.notify(notifications)
      :ok
    end
  end

  @ignored_packages [
    "nixos-install-tools",
    "tests.nixos-functions.nixos-test"
  ]

  defp flatten_attrdiff(attrdiff) do
    Enum.flat_map(~w(added changed removed), fn type ->
      attrdiff[type]
      |> List.wrap()
      |> Enum.reject(&(&1 in @ignored_packages))
      |> Enum.map(&{String.to_existing_atom(type), &1})
    end)
  end

  defp ensure_packages_exist([]), do: :ok

  defp ensure_packages_exist(attrs) do
    attrs
    |> Enum.uniq()
    |> Enum.map(&%{attribute: &1})
    |> Package.bulk_upsert_all()

    :ok
  end

  defp package_id_map([]), do: %{}

  defp package_id_map(attrs) do
    attrs
    |> Package.ids_by_attributes!()
    |> Map.new(&{&1.attribute, &1.id})
  end

  defp default_fetcher(change) do
    token = Tracker.GitHub.installation_token!()

    cache_first =
      case ChangeArtifactCache.fetch_comparison(change.number) do
        {:ok, attrdiff} -> {:ok, attrdiff}
        {:error, _} -> :miss
      end

    case cache_first do
      {:ok, _} = ok ->
        ok

      :miss ->
        fetch_from_github(change, token)
    end
  end

  defp fetch_from_github(change, token) do
    [owner, repo] = String.split(@repo, "/")

    with {:ok, run_id} <- find_merge_group_run(owner, repo, change.merge_commit_sha, token),
         {:ok, %{artifacts: artifacts}} <-
           GitHub.Actions.list_workflow_run_artifacts(owner, repo, run_id, auth: token),
         :ok <-
           ChangeArtifactCache.cache_run_artifacts(change.number, run_id, artifacts, token),
         {:ok, attrdiff} <- ChangeArtifactCache.fetch_comparison(change.number) do
      {:ok, attrdiff}
    else
      {:error, %GitHub.Error{reason: :rate_limited}} -> {:error, :rate_limited}
      other -> other
    end
  end

  defp find_merge_group_run(_owner, _repo, nil, _token), do: {:error, :no_workflow_run}

  defp find_merge_group_run(owner, repo, sha, token) do
    case GitHub.Actions.list_workflow_runs_for_repo(owner, repo,
           head_sha: sha,
           per_page: 100,
           auth: token
         ) do
      {:ok, %{workflow_runs: runs}} ->
        case Enum.find(runs, &(&1.name == "Merge Group" && &1.status == "completed")) do
          nil ->
            if Enum.find(runs, &(&1.name == "Merge Group")) do
              Logger.info("Merge Group run not yet complete for #{sha}, snoozing")
              {:snooze, 120}
            else
              {:error, :no_workflow_run}
            end

          run ->
            {:ok, run.id}
        end

      {:error, %GitHub.Error{reason: :rate_limited}} ->
        {:error, :rate_limited}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp snooze_seconds_for(bucket) do
    token = Tracker.GitHub.installation_token!()
    Tracker.GitHub.seconds_until_reset(token, bucket)
  end
end

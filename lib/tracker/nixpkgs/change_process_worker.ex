defmodule Tracker.Nixpkgs.ChangeProcessWorker do
  @moduledoc """
  Processes a single merged nixpkgs PR: fetches PR data, downloads artifacts,
  and links affected packages.
  """
  use Oban.Worker, queue: :changes, max_attempts: 10

  require Logger

  @repo "NixOS/nixpkgs"

  @doc """
  Re-enqueues processing for the given PR number(s).
  """
  def reprocess(numbers) when is_list(numbers) do
    Enum.map(numbers, &reprocess/1)
  end

  def reprocess(number) when is_integer(number) do
    case Tracker.Nixpkgs.Change.get_by_number(number) do
      {:ok, change} -> set_processing_status(change, :pending)
      _ -> :ok
    end

    %{number: number}
    |> __MODULE__.new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"number" => number}}) do
    case Tracker.GitHub.RateLimitCache.check() do
      {:limited, seconds} ->
        Logger.info("Rate limit cached, snoozing PR ##{number} for #{seconds}s")
        {:snooze, seconds}

      :ok ->
        do_perform(number)
    end
  end

  defp do_perform(number) do
    token = Tracker.GitHub.installation_token!()

    [owner, repo] = String.split(@repo, "/")

    with {:ok, pr} <- GitHub.Pulls.get(owner, repo, number, auth: token),
         {:ok, change} <- upsert_change(pr),
         {:ok, attrdiff} <-
           tag_change(fetch_attrdiff(number, change.merge_commit_sha, token), change) do
      link_packages(change, attrdiff)
      set_processing_status(change, :processed)

      Phoenix.PubSub.broadcast(
        Tracker.PubSub,
        "changes",
        {:change_processed, %{number: number}}
      )

      :ok
    else
      {:error, %GitHub.Error{reason: :rate_limited}} ->
        snooze_seconds = Tracker.GitHub.seconds_until_reset(token)
        Logger.warning("Rate limited processing PR ##{number}, snoozing #{snooze_seconds}s")
        {:snooze, snooze_seconds}

      {:snooze, _} = snooze ->
        snooze

      {:error, :artifact_expired, change} ->
        Logger.warning(msg: "Artifacts expired, discarding", pr: number)
        set_processing_status(change, :artifact_expired)
        :ok

      {:error, :no_workflow_run, change} ->
        Logger.warning(msg: "No Merge Group workflow run found, discarding", pr: number)
        set_processing_status(change, :no_workflow_run)
        :ok

      {:error, :no_comparison_artifact, change} ->
        Logger.warning(msg: "No comparison artifact found, discarding", pr: number)
        set_processing_status(change, :no_comparison_artifact)
        :ok

      {:error, :artifact_expired} ->
        Logger.warning(msg: "Artifacts expired before change upserted, discarding", pr: number)
        {:discard, :artifact_expired}

      {:error, reason, change} ->
        Logger.error("Failed to process PR ##{number}: #{inspect(reason)}")
        set_processing_status(change, :failed)
        {:error, reason}

      {:error, reason} ->
        Logger.error("Failed to process PR ##{number}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Parses a `GitHub.PullRequest` struct into a map of Change attributes.
  """
  def parse_pr_payload(pr) do
    %{
      number: pr.number,
      title: pr.title,
      state: parse_state(pr),
      author: pr.user && pr.user.login,
      author_github_id: pr.user && pr.user.id,
      merged_by_github_id: pr.merged_by && pr.merged_by.id,
      url: pr.html_url,
      base_ref: pr.base && pr.base.ref,
      head_ref: pr.head && pr.head.ref,
      labels: Enum.map(pr.labels || [], & &1.name),
      merge_commit_sha: pr.merge_commit_sha,
      gh_created_at: parse_datetime(pr.created_at),
      merged_at: parse_datetime(pr.merged_at)
    }
  end

  @doc """
  Upserts a Change record from a PR struct.
  Returns `{:ok, change}`.
  """
  def upsert_change(pr) do
    attrs = parse_pr_payload(pr)
    id_map = Tracker.Nixpkgs.Change.bulk_upsert_all([attrs])
    {_number, id} = Enum.at(id_map, 0)
    {:ok, Ash.get!(Tracker.Nixpkgs.Change, id)}
  end

  @doc """
  Links a Change to packages based on the attrdiff from changed-paths.json.
  Returns `{:ok, count}` with the number of packages linked.
  """
  def link_packages(change, attrdiff) do
    if staging_target?(change) do
      update_package_count_from_attrdiff(change, attrdiff)
      {:ok, 0}
    else
      do_link_packages(change, attrdiff)
    end
  end

  defp staging_target?(change), do: String.starts_with?(change.base_ref || "", "staging")

  defp update_package_count_from_attrdiff(change, attrdiff) do
    count =
      Enum.sum(
        for type <- ~w(added changed removed),
            do: length(attrdiff[type] || [])
      )

    Tracker.Nixpkgs.Change.update_package_count!(change, %{package_count: count})
  end

  defp do_link_packages(change, attrdiff) do
    typed_attrs =
      Enum.flat_map(~w(added changed removed), fn type ->
        Enum.map(attrdiff[type] || [], &{String.to_existing_atom(type), &1})
      end)

    case typed_attrs do
      [] ->
        {:ok, 0}

      _ ->
        all_attrs = Enum.map(typed_attrs, &elem(&1, 1))
        package_id_map = find_package_id_map(all_attrs)

        records =
          typed_attrs
          |> Enum.filter(fn {_type, attr} -> Map.has_key?(package_id_map, attr) end)
          |> Enum.map(fn {type, attr} ->
            %{change_id: change.id, package_id: package_id_map[attr], type: type}
          end)

        Tracker.Nixpkgs.ChangePackage.bulk_create_all(records)

        count = length(records)
        Tracker.Nixpkgs.Change.update_package_count!(change, %{package_count: count})

        {:ok, count}
    end
  end

  defp find_package_id_map(attributes) do
    attributes
    |> Tracker.Nixpkgs.Package.ids_by_attributes!()
    |> Map.new(&{&1.attribute, &1.id})
  end

  defp fetch_attrdiff(pr_number, merge_commit_sha, token) do
    [owner, repo] = String.split(@repo, "/")

    with {:ok, run_id} <- find_merge_group_run(owner, repo, merge_commit_sha, token),
         {:ok, attrdiff} <- download_changed_paths(owner, repo, pr_number, run_id, token) do
      {:ok, attrdiff}
    end
  end

  defp find_merge_group_run(owner, repo, sha, token) do
    case GitHub.Actions.list_workflow_runs_for_repo(owner, repo,
           head_sha: sha,
           per_page: 100,
           auth: token
         ) do
      {:ok, %{workflow_runs: runs}} ->
        case Enum.find(runs, &(&1.name == "Merge Group" && &1.status == "completed")) do
          nil ->
            pending = Enum.find(runs, &(&1.name == "Merge Group"))

            if pending do
              Logger.info("Merge Group run not yet complete for #{sha}, snoozing")
              {:snooze, 120}
            else
              {:error, :no_workflow_run}
            end

          run ->
            {:ok, run.id}
        end

      {:error, %GitHub.Error{reason: :rate_limited}} = error ->
        error

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp download_changed_paths(owner, repo, pr_number, run_id, token) do
    case GitHub.Actions.list_workflow_run_artifacts(owner, repo, run_id, auth: token) do
      {:ok, %{artifacts: artifacts}} ->
        case Enum.find(artifacts, &(&1.name == "comparison")) do
          nil ->
            {:error, :no_comparison_artifact}

          artifact ->
            Tracker.Nixpkgs.ChangeArtifactCache.fetch_comparison(
              pr_number,
              artifact.archive_download_url,
              token
            )
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp tag_change({:ok, _} = ok, _change), do: ok
  defp tag_change({:snooze, _} = snooze, _change), do: snooze
  defp tag_change({:error, reason}, change), do: {:error, reason, change}

  @doc """
  Sets the processing_status on a Change record.
  """
  def set_processing_status(change, status) do
    Tracker.Nixpkgs.Change.update_processing_status!(change, %{processing_status: status})
  end

  defp parse_state(%{merged: true}), do: :merged
  defp parse_state(%{state: "open"}), do: :open
  defp parse_state(_), do: :closed

  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(%DateTime{} = dt), do: dt
end

defmodule Tracker.Nixpkgs.ChangeProcessWorker do
  @moduledoc """
  Processes a single merged nixpkgs PR: fetches PR data, downloads artifacts,
  and links affected packages.
  """
  use Oban.Worker, queue: :changes, max_attempts: 10

  require Logger

  @repo "NixOS/nixpkgs"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"number" => number}}) do
    [owner, repo] = String.split(@repo, "/")
    token = Tracker.GitHub.installation_token!()

    with {:ok, pr} <- GitHub.Pulls.get(owner, repo, number, auth: token),
         {:ok, change} <- upsert_change(pr),
         {:ok, attrdiff} <- fetch_attrdiff(pr.merge_commit_sha, token) do
      link_packages(change, attrdiff)
      :ok
    else
      {:error, %GitHub.Error{reason: :rate_limited}} ->
        Logger.warning("Rate limited processing PR ##{number}, snoozing")
        {:snooze, 60}

      {:snooze, _} = snooze ->
        snooze

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
    attributes =
      (attrdiff["added"] || []) ++
        (attrdiff["changed"] || []) ++
        (attrdiff["removed"] || [])

    case attributes do
      [] ->
        {:ok, 0}

      attrs ->
        package_ids = find_package_ids(attrs)

        records = Enum.map(package_ids, fn id -> %{change_id: change.id, package_id: id} end)
        Tracker.Nixpkgs.ChangePackage.bulk_create_all(records)

        {:ok, length(package_ids)}
    end
  end

  defp find_package_ids(attributes) do
    attributes
    |> Tracker.Nixpkgs.Package.ids_by_attributes!()
    |> Enum.map(& &1.id)
  end

  defp fetch_attrdiff(merge_commit_sha, token) do
    [owner, repo] = String.split(@repo, "/")

    with {:ok, run_id} <- find_merge_group_run(owner, repo, merge_commit_sha, token),
         {:ok, attrdiff} <- download_changed_paths(owner, repo, run_id, token) do
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
              {:error, "No Merge Group workflow run found for #{sha}"}
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

  defp download_changed_paths(owner, repo, run_id, token) do
    case GitHub.Actions.list_workflow_run_artifacts(owner, repo, run_id, auth: token) do
      {:ok, %{artifacts: artifacts}} ->
        case Enum.find(artifacts, &(&1.name == "comparison")) do
          nil ->
            {:error, "No comparison artifact found for run #{run_id}"}

          artifact ->
            download_and_extract_attrdiff(artifact.archive_download_url, token)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp download_and_extract_attrdiff(archive_url, token) do
    case Req.get(archive_url,
           headers: %{"authorization" => "bearer #{token}", "user-agent" => "Tracker"},
           redirect: true,
           decode_body: false
         ) do
      {:ok, %{status: 200, body: zip_body}} ->
        extract_attrdiff_from_zip(zip_body)

      {:ok, %{status: status}} ->
        {:error, "Artifact download failed with status #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_attrdiff_from_zip(zip_body) do
    case :zip.extract(zip_body, [:memory]) do
      {:ok, files} ->
        case List.keyfind(files, ~c"changed-paths.json", 0) do
          {_, contents} ->
            case Jason.decode(contents) do
              {:ok, %{"attrdiff" => attrdiff}} ->
                {:ok, attrdiff}

              {:ok, _} ->
                {:error, "changed-paths.json missing attrdiff key"}

              {:error, reason} ->
                {:error, "Failed to parse changed-paths.json: #{inspect(reason)}"}
            end

          nil ->
            {:error, "changed-paths.json not found in comparison artifact"}
        end

      {:error, reason} ->
        {:error, "Failed to extract zip: #{inspect(reason)}"}
    end
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

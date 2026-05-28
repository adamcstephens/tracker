defmodule Tracker.Nixpkgs.ReconstructionJob.Claim do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias Tracker.Nixpkgs.{Change, ReconstructionJob}
  alias Tracker.Repo

  @lease_seconds 3 * 60 * 60

  @impl Ash.Resource.Actions.Implementation
  def run(_input, _opts, _context) do
    parent_sha_fetcher =
      Application.get_env(:tracker, :reconstruction_parent_sha_fetcher) ||
        (&fetch_parent_sha_from_github/1)

    Repo.transaction(fn ->
      case pick_eligible_change() do
        nil ->
          %{result: :none}

        change ->
          retire_stale_claims(change.id)

          case parent_sha_fetcher.(change.merge_commit_sha) do
            {:ok, base_sha} ->
              now = DateTime.utc_now()
              lease_token = generate_lease_token()
              lease_expires_at = DateTime.add(now, @lease_seconds, :second)

              {:ok, job, _notifications} =
                ReconstructionJob
                |> Ash.Changeset.for_create(
                  :create_internal,
                  %{
                    change_id: change.id,
                    claimed_at: now,
                    lease_expires_at: lease_expires_at,
                    lease_token: lease_token,
                    status: :claimed
                  }
                )
                |> Ash.create(authorize?: false, return_notifications?: true)

              %{
                result: :claimed,
                job_id: job.id,
                change_id: change.id,
                pr_number: change.number,
                base_sha: base_sha,
                head_sha: change.merge_commit_sha,
                lease_token: lease_token,
                lease_expires_at: lease_expires_at
              }

            {:error, reason} ->
              Repo.rollback({:parent_sha_lookup_failed, reason})
          end
      end
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp pick_eligible_change do
    require Ash.Query

    Change
    |> Ash.Query.filter(
      processing_status == :artifact_expired and
        not is_nil(merge_commit_sha) and
        not exists(
          reconstruction_jobs,
          status == :claimed and lease_expires_at > ^DateTime.utc_now()
        )
    )
    |> Ash.Query.sort(merged_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> List.first()
  end

  defp retire_stale_claims(change_id) do
    require Ash.Query

    ReconstructionJob
    |> Ash.Query.filter(
      change_id == ^change_id and status == :claimed and
        lease_expires_at <= ^DateTime.utc_now()
    )
    |> Ash.read!(authorize?: false)
    |> Enum.each(fn job ->
      job
      |> Ash.Changeset.for_update(:update_internal, %{
        status: :failed,
        last_error: "lease expired"
      })
      |> Ash.update!(authorize?: false, return_notifications?: true)
    end)
  end

  defp generate_lease_token do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  defp fetch_parent_sha_from_github(merge_commit_sha) do
    repo = Application.get_env(:tracker, :nixpkgs_repo, "NixOS/nixpkgs")
    [owner, repo] = String.split(repo, "/")
    token = Tracker.GitHub.installation_token!()

    case GitHub.Repos.get_commit(owner, repo, merge_commit_sha, auth: token) do
      {:ok, %{parents: [%{sha: sha} | _]}} -> {:ok, sha}
      {:ok, %{parents: []}} -> {:error, :no_parents}
      {:error, reason} -> {:error, reason}
    end
  end
end

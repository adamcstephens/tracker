defmodule Tracker.Nixpkgs.ReconstructionJob.SubmitResult do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  alias Tracker.Nixpkgs.{ChangeArtifactCache, ChangeArtifactRefreshWorker, ReconstructionJob}
  alias Tracker.Nixpkgs.ChangeArtifactCache.Meta
  alias Tracker.Nixpkgs.S3Cache

  @impl Ash.Resource.Actions.Implementation
  def run(input, _opts, _context) do
    id = input.arguments.id
    lease_token = input.arguments.lease_token
    zip_bytes = input.arguments.zip_bytes

    with {:ok, job} <- ReconstructionJob.get_by_id(id, authorize?: false, load: [:change]),
         :ok <- check_active_lease(job, lease_token),
         {:ok, _attrdiff} <- ChangeArtifactCache.extract_attrdiff(zip_bytes),
         :ok <- write_to_s3(job.change.number, zip_bytes),
         {:ok, updated} <- mark_succeeded(job),
         :ok <- enqueue_refresh(job.change.number) do
      {:ok, %{result: :succeeded, job_id: updated.id}}
    end
  end

  defp check_active_lease(%ReconstructionJob{status: :claimed} = job, lease_token) do
    cond do
      job.lease_token != lease_token ->
        {:error, :invalid_lease_token}

      DateTime.compare(job.lease_expires_at, DateTime.utc_now()) == :lt ->
        {:error, :lease_expired}

      true ->
        :ok
    end
  end

  defp check_active_lease(_job, _lease_token), do: {:error, :not_claimed}

  defp write_to_s3(pr_number, zip_bytes) do
    case S3Cache.config() do
      nil ->
        :ok

      config ->
        zip_key = ChangeArtifactCache.cache_key(pr_number, "comparison")
        meta_key = ChangeArtifactCache.meta_key(pr_number)

        meta = %Meta{
          run_id: nil,
          names: ["comparison"],
          source: :merge,
          provenance: :reconstruction
        }

        with :ok <- S3Cache.put_object(config, zip_key, zip_bytes),
             :ok <- S3Cache.put_object(config, meta_key, :erlang.term_to_binary(meta)) do
          :ok
        end
    end
  end

  defp mark_succeeded(job) do
    job
    |> Ash.Changeset.for_update(:update_internal, %{status: :succeeded})
    |> Ash.update(authorize?: false)
  end

  defp enqueue_refresh(pr_number) do
    case ChangeArtifactRefreshWorker.new(%{number: pr_number, reason: "merged"})
         |> Oban.insert() do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end

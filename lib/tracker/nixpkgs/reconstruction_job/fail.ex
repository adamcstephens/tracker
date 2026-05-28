defmodule Tracker.Nixpkgs.ReconstructionJob.Fail do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  alias Tracker.Nixpkgs.ReconstructionJob

  @impl Ash.Resource.Actions.Implementation
  def run(input, _opts, _context) do
    id = input.arguments.id
    lease_token = input.arguments.lease_token
    reason = input.arguments.reason
    detail = Map.get(input.arguments, :detail)

    last_error =
      case detail do
        nil -> reason
        "" -> reason
        detail -> "#{reason}: #{detail}"
      end

    with {:ok, job} <- ReconstructionJob.get_by_id(id, authorize?: false),
         :ok <- check_active_lease(job, lease_token) do
      job
      |> Ash.Changeset.for_update(:update_internal, %{
        status: :failed,
        last_error: last_error
      })
      |> Ash.update(authorize?: false)
      |> case do
        {:ok, updated} -> {:ok, %{result: :failed, job_id: updated.id}}
        {:error, error} -> {:error, error}
      end
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
end

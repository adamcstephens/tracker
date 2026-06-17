defmodule Tracker.Nixpkgs.BulkCreate do
  @moduledoc """
  Shared runner for the chunked `Ash.bulk_create` upserts/inserts behind the
  resources' `bulk_*_all` helpers.

  Raises when a batch reports errors instead of silently dropping rows, so an
  ingestion step fails loudly (and `StepWorker` marks its pipeline failed)
  rather than completing with incomplete data. Every consumer is either an
  upsert or a delete-first idempotent step, so a raise only ever signals a
  genuine, unexpected error.
  """

  @doc """
  Runs `records` through `action` on `resource` in `batch_size` chunks,
  raising if any chunk does not fully succeed.
  """
  def run!(records, resource, action, batch_size) do
    records
    |> Stream.chunk_every(batch_size)
    |> Enum.each(fn chunk ->
      case Ash.bulk_create(chunk, resource, action,
             batch_size: batch_size,
             return_errors?: true
           ) do
        %Ash.BulkResult{status: :success} ->
          :ok

        %Ash.BulkResult{errors: errors} ->
          raise "bulk #{inspect(resource)}.#{action} failed: #{inspect(errors, limit: 5)}"
      end
    end)
  end
end

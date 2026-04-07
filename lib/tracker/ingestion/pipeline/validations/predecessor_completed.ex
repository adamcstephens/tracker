defmodule Tracker.Ingestion.Pipeline.Validations.PredecessorCompleted do
  use Ash.Resource.Validation

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    pipeline = changeset.data

    case pipeline.predecessor_id do
      nil ->
        :ok

      predecessor_id ->
        case Ash.get(Tracker.Ingestion.Pipeline, predecessor_id) do
          {:ok, %{status: :completed}} ->
            :ok

          {:ok, %{status: status}} ->
            {:error,
             field: :status,
             message: "predecessor pipeline %{predecessor_id} is not completed (%{status})",
             vars: %{predecessor_id: predecessor_id, status: status}}

          {:error, _} ->
            {:error,
             field: :predecessor_id,
             message: "predecessor pipeline %{predecessor_id} not found",
             vars: %{predecessor_id: predecessor_id}}
        end
    end
  end

  @impl true
  def atomic(changeset, opts, context) do
    validate(changeset, opts, context)
  end
end

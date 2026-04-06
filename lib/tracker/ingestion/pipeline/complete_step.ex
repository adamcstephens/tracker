defmodule Tracker.Ingestion.Pipeline.CompleteStep do
  @moduledoc """
  Manual update implementation for the complete_step action.

  Uses a direct Ecto query to atomically append to the completed_steps
  array, bypassing Ash's atomic casting limitation for array types.
  """

  use Ash.Resource.ManualUpdate

  @impl true
  def update(changeset, _opts, _context) do
    pipeline = changeset.data
    step = Ash.Changeset.get_argument(changeset, :step)
    now = DateTime.utc_now()

    %{rows: [[completed_steps_raw]]} =
      Tracker.Repo.query!(
        "UPDATE ingestion_pipelines SET completed_steps = CASE WHEN $1 = ANY(completed_steps) THEN completed_steps ELSE array_append(completed_steps, $1) END, updated_at = $2 WHERE id = $3 RETURNING completed_steps",
        [to_string(step), now, pipeline.id]
      )

    completed_steps = Enum.map(completed_steps_raw, &String.to_existing_atom/1)

    {:ok, %{pipeline | completed_steps: completed_steps, updated_at: now}}
  end
end

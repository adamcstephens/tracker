defmodule Tracker.Ingestion.Step do
  @moduledoc """
  Behaviour for ingestion pipeline steps.

  Each step module implements `run/1` which receives a `StepContext`
  and performs a discrete unit of ingestion work. Steps must be
  idempotent to support safe retries.
  """

  @callback run(Tracker.Ingestion.StepContext.t()) :: :ok | {:error, term()}

  @doc """
  Returns the timeout in milliseconds for this step.
  """
  @callback timeout() :: pos_integer()
end

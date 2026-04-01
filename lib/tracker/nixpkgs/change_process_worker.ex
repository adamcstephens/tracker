defmodule Tracker.Nixpkgs.ChangeProcessWorker do
  @moduledoc """
  Processes a single merged nixpkgs PR: fetches PR data, downloads artifacts,
  and links affected packages.
  """
  use Oban.Worker, queue: :changes, max_attempts: 10

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"number" => _number}}) do
    # TODO: implement in trk-60
    :ok
  end
end

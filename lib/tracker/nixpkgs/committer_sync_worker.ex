defmodule Tracker.Nixpkgs.CommitterSyncWorker do
  @moduledoc "Reconciles informational committer status from the public membership snapshot."
  use Oban.Worker, queue: :changes, max_attempts: 3, unique: [period: 60]

  require Logger

  alias Tracker.Nixpkgs.Maintainer

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case run() do
      {:ok, updated} ->
        Logger.info(msg: "committer sync finished", updated: updated)
        :ok

      {:error, reason} = error ->
        Logger.warning(msg: "committer sync failed", reason: inspect(reason))
        error
    end
  end

  def run(opts \\ []) do
    fetch = Keyword.get(opts, :fetch, &fetch_files/0)

    with {:ok, files} <- fetch.() do
      handles =
        for path <- files,
            ["members", handle] <- [String.split(path, "/")],
            into: MapSet.new(),
            do: String.downcase(handle)

      Ash.DataLayer.transaction(Maintainer, fn -> reconcile(handles) end)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp reconcile(handles) do
    Maintainer.read!()
    |> Enum.reject(fn %Maintainer{} = maintainer ->
      maintainer.committer == member?(maintainer, handles)
    end)
    |> Enum.group_by(&member?(&1, handles))
    |> Enum.reduce(0, fn {committer, records}, updated ->
      case Ash.bulk_update(records, :set_committer, %{committer: committer},
             resource: Maintainer,
             strategy: [:atomic_batches],
             return_errors?: true
           ) do
        %Ash.BulkResult{status: :success} -> updated + length(records)
        %Ash.BulkResult{errors: errors} -> Ash.DataLayer.rollback(Maintainer, errors)
      end
    end)
  end

  defp member?(%Maintainer{github: nil}, _handles), do: false

  defp member?(%Maintainer{} = maintainer, handles) do
    MapSet.member?(handles, String.downcase(maintainer.github))
  end

  defp fetch_files do
    GitHub.Repos.list_tree_files("NixOS", "nixpkgs-committers", "main")
  end
end

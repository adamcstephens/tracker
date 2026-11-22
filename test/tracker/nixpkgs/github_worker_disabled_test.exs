defmodule Tracker.Nixpkgs.GitHubWorkerDisabledTest do
  use ExUnit.Case, async: false

  setup do
    previous = Application.get_env(:tracker, :github_enabled)
    Application.put_env(:tracker, :github_enabled, false)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:tracker, :github_enabled)
      else
        Application.put_env(:tracker, :github_enabled, previous)
      end
    end)
  end

  for worker <- [
        Tracker.Nixpkgs.ChangeDiscoveryWorker,
        Tracker.Nixpkgs.ChangeRefreshWorker,
        Tracker.Nixpkgs.ChangeReconcileWorker,
        Tracker.Nixpkgs.ChangeArtifactRefreshWorker,
        Tracker.Nixpkgs.ChangeArtifactReconcileWorker,
        Tracker.Nixpkgs.BackportReconcileWorker,
        Tracker.Nixpkgs.CommitterSyncWorker
      ] do
    test "#{inspect(worker)} cancels persisted jobs when GitHub is disabled" do
      job = %Oban.Job{args: %{"number" => 1, "reason" => "merged"}, attempt: 1, max_attempts: 10}

      assert {:cancel, "GitHub integration is disabled"} = unquote(worker).perform(job)
    end
  end
end

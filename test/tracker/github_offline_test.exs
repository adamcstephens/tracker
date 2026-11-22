defmodule Tracker.GitHubOfflineTest do
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

  test "REST rejects requests before authentication or HTTP" do
    assert {:error, %GitHub.Error{reason: :disabled}} =
             GitHub.Client.get("/user", plug: fn _conn -> flunk("HTTP attempted") end)
  end

  test "uncached comparison artifacts reject downloads even with an explicit token" do
    artifacts = [
      %{name: "comparison", archive_download_url: "https://api.github.com/artifacts/1/zip"}
    ]

    assert {:error, %GitHub.Error{reason: :disabled}} =
             Tracker.Nixpkgs.ChangeArtifactCache.cache_run_artifacts(
               System.unique_integer([:positive]),
               1,
               artifacts,
               "token",
               req_options: [plug: fn _conn -> flunk("HTTP attempted") end]
             )
  end

  test "installation tokens reject before reading credentials" do
    assert_raise RuntimeError, "GitHub integration is disabled", fn ->
      Tracker.GitHub.installation_token!()
    end
  end

  test "GraphQL rejects requests even with an explicit token" do
    opts = [token: "token", plug: fn _conn -> flunk("HTTP attempted") end]

    calls = [
      fn -> Tracker.GitHub.GraphQL.fetch_prs(["node"], opts) end,
      fn ->
        Tracker.GitHub.GraphQL.search_repository_prs("NixOS/nixpkgs", DateTime.utc_now(), opts)
      end,
      fn -> Tracker.GitHub.GraphQL.fetch_numbers("NixOS/nixpkgs", [1], opts) end,
      fn -> Tracker.GitHub.GraphQL.fetch_pr_commit_messages(1, opts) end,
      fn -> Tracker.GitHub.GraphQL.fetch_commit_pr_numbers(["sha"], opts) end
    ]

    Enum.each(calls, fn call ->
      assert {:error, %GitHub.Error{reason: :disabled, message: "GitHub integration is disabled"}} =
               call.()
    end)
  end

  test "offline Oban configuration stops GitHub workers and their cron schedules" do
    config = [
      queues: [changes: 10, ingestion: 1],
      plugins: [
        {Oban.Plugins.Cron,
         crontab: [
           {"* * * * *", Tracker.Nixpkgs.ChangeDiscoveryWorker},
           {"* * * * *", Tracker.Ingestion.CronWorker, queue: :ingestion},
           {"* * * * *", Tracker.Notifications.InboxPrunerWorker}
         ]}
      ]
    ]

    offline = Tracker.Application.oban_config(config)
    assert offline[:queues] == config[:queues]
    assert offline[:queues][:ingestion] == 1

    assert offline[:plugins] == [
             {Oban.Plugins.Cron,
              crontab: [{"* * * * *", Tracker.Notifications.InboxPrunerWorker}]}
           ]
  end
end

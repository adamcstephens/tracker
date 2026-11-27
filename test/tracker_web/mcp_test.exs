defmodule TrackerWeb.McpTest do
  use TrackerWeb.ConnCase, async: false

  alias Tracker.Accounts.{ApiToken, User}
  import Tracker.Fixtures
  alias Tracker.Ingestion.{IngestionRun, Pipeline}

  test "authenticated user initializes, discovers and calls channel tools" do
    user = service_account([:user])
    %{token: token} = ApiToken.issue!(user.id, %{}, actor: user)

    initialize =
      rpc(token, "initialize", %{
        protocolVersion: "2025-11-25",
        capabilities: %{},
        clientInfo: %{name: "tracker-test", version: "1"}
      })

    assert json_response(initialize, 200)["result"]["protocolVersion"] == "2025-11-25"

    tools = json_response(rpc(token, "tools/list", %{}), 200)["result"]["tools"]

    assert Enum.sort(Enum.map(tools, & &1["name"])) == [
             "list_channel_heads",
             "list_channel_revisions"
           ]

    channel = channel!()
    revision = channel_revision!(channel)

    heads = call_tool(token, "list_channel_heads", %{})
    assert Enum.any?(heads["results"], &(&1["name"] == channel.name))

    revisions =
      call_tool(token, "list_channel_revisions", %{
        input: %{channel: channel.name, from: "2020-01-01T00:00:00Z", to: "2100-01-01T00:00:00Z"},
        limit: 2
      })

    assert Enum.map(revisions["results"], & &1["revision"]) == [revision.revision]
  end

  test "normal user cannot call the hidden ingestion tool directly" do
    user = service_account([:user])
    %{token: token} = ApiToken.issue!(user.id, %{}, actor: user)
    ingestion_run_with_private_pipeline!()

    response =
      rpc(token, "tools/call", %{
        name: "list_ingestion_runs",
        arguments: %{input: ingestion_window()}
      })

    assert %{"error" => %{"code" => -32_602, "message" => message}} =
             json_response(response, 200)

    assert message == "Tool not found: list_ingestion_runs"
    refute Map.has_key?(json_response(response, 200), "result")
    refute response.resp_body =~ "private-ingestion"
  end

  test "admin discovers and calls the ingestion tool" do
    admin = service_account([:user, :admin])
    %{token: token} = ApiToken.issue!(admin.id, %{}, actor: admin)
    tools = json_response(rpc(token, "tools/list", %{}), 200)["result"]["tools"]

    assert Enum.sort(Enum.map(tools, & &1["name"])) == [
             "list_channel_heads",
             "list_channel_revisions",
             "list_ingestion_runs"
           ]

    run = ingestion_run_with_private_pipeline!()

    runs = call_tool(token, "list_ingestion_runs", %{input: ingestion_window(), limit: 2})
    assert Enum.map(runs["results"], & &1["id"]) == [run.id]
    [result] = runs["results"]
    assert result["status"] == "running"

    assert result["pipeline_counts"] == %{
             "pending" => 0,
             "running" => 0,
             "completed" => 1,
             "failed" => 1,
             "stuck" => 0
           }

    assert [%{"status" => "failed", "failed_step" => "create_revision"} = pipeline] =
             result["unfinished_pipelines"]

    refute Map.has_key?(pipeline, "error")
    refute Map.has_key?(pipeline, "base_url")
    refute Jason.encode!(runs) =~ "private-ingestion"
  end

  defp ingestion_window do
    %{window_start: "2020-01-01T00:00:00Z", window_end: "2100-01-01T00:00:00Z"}
  end

  test "rejects invalid and revoked API tokens" do
    assert rpc("invalid", "tools/list", %{}).status == 401

    user = service_account([:user])
    %{token: token, jti: jti} = ApiToken.issue!(user.id, %{}, actor: user)
    assert {:ok, _} = ApiToken.revoke(jti, actor: user)

    assert json_response(rpc(token, "tools/list", %{}), 401) == %{"error" => "revoked"}
  end

  test "rejects anonymous MCP requests" do
    conn = rpc(nil, "tools/list", %{})

    assert json_response(conn, 401) == %{"error" => "missing_bearer_token"}
  end

  defp ingestion_run_with_private_pipeline! do
    run = IngestionRun.create!(%{type: :cron_update, started_at: DateTime.utc_now()})
    channel = channel!()

    Pipeline.create!(%{
      channel_id: channel.id,
      revision: "mcp-revision",
      base_url: "https://private-ingestion.example/secret",
      released_at: DateTime.utc_now(),
      active_steps: [:create_revision],
      sequence: 0,
      ingestion_run_id: run.id
    })
    |> Pipeline.mark_failed!(:create_revision, "private-ingestion-error")

    Pipeline.create!(%{
      channel_id: channel.id,
      revision: "completed-revision",
      base_url: "https://private-ingestion.example/complete",
      released_at: DateTime.utc_now(),
      active_steps: [],
      sequence: 1,
      ingestion_run_id: run.id
    })
    |> Pipeline.mark_completed!()

    run
  end

  defp service_account(roles) do
    User.create_service_account!(
      "mcp-#{System.unique_integer([:positive])}",
      roles,
      authorize?: false
    )
  end

  defp call_tool(token, name, arguments) do
    body = json_response(rpc(token, "tools/call", %{name: name, arguments: arguments}), 200)
    assert %{"result" => %{"isError" => false, "content" => [%{"text" => text}]}} = body
    Jason.decode!(text)
  end

  defp rpc(token, method, params) do
    conn =
      build_conn()
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("content-type", "application/json")

    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn

    post(conn, "/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: method, params: params}))
  end
end

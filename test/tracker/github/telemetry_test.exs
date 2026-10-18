defmodule Tracker.GitHub.TelemetryTest do
  use ExUnit.Case, async: true

  alias GitHub.Client
  alias GitHub.Client.S3Config
  alias GitHub.Error
  alias Tracker.GitHub.GraphQL
  alias Tracker.GitHub.RateLimitCache

  @quota_event [:tracker, :github, :rate_limit]
  @limited_event [:tracker, :github, :rate_limited]
  @cost_event [:tracker, :github, :graphql, :cost]
  @reset 1_893_456_000

  setup do
    pid = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach_many(
      handler,
      [@quota_event, @limited_event, @cost_event],
      fn event, measurements, metadata, owner ->
        if self() == owner, do: send(owner, {:github_metric, event, measurements, metadata})
      end,
      pid
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    table = :ets.new(__MODULE__, [:set, :public])
    %{table: table}
  end

  test "REST success observes quota without marking the request rate limited" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn |> quota_headers("core", 4999) |> Req.Test.json(%{number: 1})
    end)

    before = System.os_time(:second)
    assert {:ok, %{"number" => 1}} = Client.get("/repos/o/r/pulls/1", rest_opts())
    assert_quota("core", 5000, 4999, before)
    refute_receive {:github_metric, @limited_event, _, _}
  end

  test "REST errors observe available quota and count a classified limit only once" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> quota_headers("core", 0)
      |> Plug.Conn.send_resp(403, ~s({"message":"API rate limit exceeded for token"}))
    end)

    before = System.os_time(:second)
    assert {:error, %Error{reason: :rate_limited}} = Client.get("/x", rest_opts())
    assert_quota("core", 5000, 0, before)
    assert_receive {:github_metric, @limited_event, _, %{resource: "core"}}
    refute_receive {:github_metric, @limited_event, _, _}

    Req.Test.stub(__MODULE__, fn conn ->
      conn |> quota_headers("search", 29) |> Plug.Conn.send_resp(404, ~s({"message":"Not Found"}))
    end)

    assert {:error, %Error{reason: :not_found}} = Client.get("/x", rest_opts())
    assert_quota("search", 5000, 29, before)
    refute_receive {:github_metric, @limited_event, _, _}
  end

  test "cached REST 304 observes the actual response headers before serving its cached body" do
    cache = %S3Config{
      bucket: "test-bucket",
      access_key_id: "key",
      secret_access_key: "secret",
      endpoint: "http://localhost:4444",
      region: "garage",
      plug: {Req.Test, __MODULE__}
    }

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/test-bucket/" <> _ ->
          Req.Test.json(conn, %{
            etag: ~s("cached"),
            response: ~s({"number":1}),
            headers: %{"x-ratelimit-remaining" => "12"}
          })

        _ ->
          assert Plug.Conn.get_req_header(conn, "if-none-match") == [~s("cached")]
          conn |> quota_headers("core", 4012) |> Plug.Conn.send_resp(304, "")
      end
    end)

    before = System.os_time(:second)
    assert {:ok, %{"number" => 1}} = Client.get("/x", rest_opts() ++ [s3_cache: cache])
    assert_quota("core", 5000, 4012, before)
    refute_receive {:github_metric, @quota_event, _, _}
    refute_receive {:github_metric, @limited_event, _, _}
  end

  test "missing or invalid headers do not fabricate quota fields or unbounded resource labels" do
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, %{}) end)
    assert {:ok, %{}} = Client.get("/x", rest_opts())
    refute_receive {:github_metric, @quota_event, _, _}

    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("x-ratelimit-resource", "secret-token-arbitrary-id")
      |> Plug.Conn.put_resp_header("x-ratelimit-limit", "invalid")
      |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "17")
      |> Req.Test.json(%{})
    end)

    assert {:ok, %{}} = Client.get("/x", rest_opts())
    assert_receive {:github_metric, @quota_event, measurements, %{resource: "core"} = metadata}
    assert measurements.remaining == 17
    refute Map.has_key?(measurements, :limit)
    refute Map.has_key?(measurements, :reset_timestamp_seconds)
    assert Map.keys(metadata) == [:resource]
  end

  for path <- [:nodes, :search, :numbers] do
    test "GraphQL #{path} observes a high quota and cost without activating throttling", %{
      table: table
    } do
      path = unquote(path)
      Req.Test.stub(__MODULE__, graphql_response(path, 4500))
      before = System.os_time(:second)
      assert {:ok, _} = graphql_call(path, table)
      assert_quota("graphql", 5000, 4500, before)
      assert_receive {:github_metric, @cost_event, %{cost: 3}, %{resource: "graphql"}}
      refute_receive {:github_metric, @cost_event, _, _}
      refute_receive {:github_metric, @limited_event, _, _}
      assert RateLimitCache.check(:graphql, table) == :ok
    end
  end

  test "GraphQL partial data and RATE_LIMITED errors are measured once without changing successful decoding",
       %{table: table} do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        data: %{nodes: [nil], rateLimit: quota(45)},
        errors: [%{type: "RATE_LIMITED", message: "partial quota failure"}]
      })
    end)

    before = System.os_time(:second)
    assert {:ok, %{"PR_1" => :not_found}} = graphql_call(:nodes, table)
    assert_quota("graphql", 5000, 45, before)
    assert_receive {:github_metric, @cost_event, %{cost: 3}, %{resource: "graphql"}}
    assert_receive {:github_metric, @limited_event, _, %{resource: "graphql"}}
    refute_receive {:github_metric, @cost_event, _, _}
    refute_receive {:github_metric, @limited_event, _, _}
    assert {:limited, _} = RateLimitCache.check(:graphql, table)
  end

  test "GraphQL quota survives malformed application data before body handling", %{table: table} do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{data: %{rateLimit: quota(4000)}})
    end)

    before = System.os_time(:second)

    assert {:error, %Error{message: "Malformed GitHub GraphQL response"}} =
             graphql_call(:nodes, table)

    assert_quota("graphql", 5000, 4000, before)
    assert_receive {:github_metric, @cost_event, %{cost: 3}, %{resource: "graphql"}}
    assert RateLimitCache.check(:graphql, table) == :ok
  end

  test "HTTP 200 errors-only GraphQL limits count without invented quota or cost", %{table: table} do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        data: nil,
        errors: [%{type: "RATE_LIMITED"}, %{type: "RATE_LIMITED"}]
      })
    end)

    assert {:error, %Error{reason: :rate_limited}} = graphql_call(:nodes, table)
    assert_receive {:github_metric, @limited_event, _, %{resource: "graphql"}}
    refute_receive {:github_metric, @limited_event, _, _}
    refute_receive {:github_metric, @quota_event, _, _}
    refute_receive {:github_metric, @cost_event, _, _}
  end

  test "GraphQL HTTP limit responses preserve headers and count once even with RATE_LIMITED body",
       %{table: table} do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> quota_headers("graphql", 0)
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(429, Jason.encode!(%{errors: [%{type: "RATE_LIMITED"}]}))
    end)

    before = System.os_time(:second)
    assert {:error, %Error{reason: :rate_limited}} = graphql_call(:search, table)
    assert_quota("graphql", 5000, 0, before)
    assert_receive {:github_metric, @limited_event, _, %{resource: "graphql"}}
    refute_receive {:github_metric, @limited_event, _, _}
    refute_receive {:github_metric, @cost_event, _, _}
  end

  test "PromEx consumes response observations and retains last values after their reset time", %{
    table: table
  } do
    owner = self()
    name = :tracker_github_quota_test_collector

    metrics =
      Tracker.PromEx.GitHub.event_metrics([])
      |> List.wrap()
      |> Enum.flat_map(& &1.metrics)
      |> Enum.map(fn metric -> %{metric | keep: fn _ -> self() == owner end} end)

    start_supervised!(
      {TelemetryMetricsPrometheus.Core, name: name, metrics: metrics, start_async: false}
    )

    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> quota_headers("core", 4010)
      |> Plug.Conn.put_resp_header("x-ratelimit-reset", "1")
      |> Req.Test.json(%{})
    end)

    assert {:ok, %{}} = Client.get("/x", rest_opts())
    scrape = TelemetryMetricsPrometheus.Core.scrape(name)
    assert scrape =~ "tracker_github_rate_limit_limit{resource=\"core\"} 5000"
    assert scrape =~ "tracker_github_rate_limit_remaining{resource=\"core\"} 4010"
    assert scrape =~ "tracker_github_rate_limit_reset_timestamp_seconds{resource=\"core\"} 1"
    assert scrape =~ "tracker_github_rate_limit_observed_timestamp_seconds{resource=\"core\"} "
    assert TelemetryMetricsPrometheus.Core.scrape(name) == scrape

    Req.Test.stub(__MODULE__, graphql_response(:nodes, 4500))
    assert {:ok, _} = graphql_call(:nodes, table)
    assert {:ok, _} = graphql_call(:nodes, table)
    scrape = TelemetryMetricsPrometheus.Core.scrape(name)
    assert scrape =~ "tracker_github_graphql_cost_total{resource=\"graphql\"} 6"
    assert scrape =~ "tracker_github_rate_limit_remaining{resource=\"core\"} 4010"
    assert scrape =~ "tracker_github_rate_limit_remaining{resource=\"graphql\"} 4500"

    Req.Test.stub(__MODULE__, fn conn ->
      conn |> quota_headers("core", 0) |> Plug.Conn.send_resp(429, ~s({"message":"slow down"}))
    end)

    assert {:error, %Error{reason: :rate_limited}} = Client.get("/x", rest_opts())
    assert {:error, %Error{reason: :rate_limited}} = Client.get("/x", rest_opts())
    scrape = TelemetryMetricsPrometheus.Core.scrape(name)
    assert scrape =~ "tracker_github_rate_limited_total{resource=\"core\"} 2"
    assert scrape =~ "tracker_github_rate_limit_remaining{resource=\"core\"} 0"
    assert scrape =~ "tracker_github_graphql_cost_total{resource=\"graphql\"} 6"
  end

  defp rest_opts, do: [plug: {Req.Test, __MODULE__}]

  defp graphql_call(path, table) do
    opts = [token: "test-token", plug: {Req.Test, __MODULE__}, rate_limit_table: table]

    case path do
      :nodes -> GraphQL.fetch_prs(["PR_1"], opts)
      :search -> GraphQL.search_repository_prs("owner/repo", ~U[2026-01-01 00:00:00Z], opts)
      :numbers -> GraphQL.fetch_numbers("owner/repo", [1], opts)
    end
  end

  defp graphql_response(path, remaining) do
    fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(raw)
      assert request["query"] =~ ~r/rateLimit\s*\{[^}]*\blimit\b/

      data =
        case path do
          :nodes -> %{nodes: [nil]}
          :search -> %{search: %{nodes: [], issueCount: 0, pageInfo: %{hasNextPage: false}}}
          :numbers -> %{repository: %{n1: nil}}
        end

      Req.Test.json(conn, %{data: Map.put(data, :rateLimit, quota(remaining))})
    end
  end

  defp quota(remaining) do
    %{limit: 5000, remaining: remaining, resetAt: "2030-01-01T00:00:00Z", cost: 3}
  end

  defp quota_headers(conn, resource, remaining) do
    conn
    |> Plug.Conn.put_resp_header("x-ratelimit-resource", resource)
    |> Plug.Conn.put_resp_header("x-ratelimit-limit", "5000")
    |> Plug.Conn.put_resp_header("x-ratelimit-remaining", to_string(remaining))
    |> Plug.Conn.put_resp_header("x-ratelimit-reset", to_string(@reset))
  end

  defp assert_quota(resource, limit, remaining, before) do
    assert_receive {:github_metric, @quota_event, measurements, %{resource: ^resource}}
    assert measurements.limit == limit
    assert measurements.remaining == remaining
    assert measurements.reset_timestamp_seconds == @reset
    assert measurements.observed_timestamp_seconds >= before
    assert measurements.observed_timestamp_seconds <= System.os_time(:second)
  end
end

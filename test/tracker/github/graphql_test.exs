defmodule Tracker.GitHub.GraphQLTest do
  use ExUnit.Case, async: true

  alias GitHub.Error
  alias Tracker.GitHub.GraphQL
  alias Tracker.GitHub.GraphQL.PullRequest
  alias Tracker.GitHub.RateLimitCache

  setup do
    table = :"rate_limit_cache_graphql_#{System.unique_integer([:positive])}"
    RateLimitCache.new(table)
    on_exit(fn -> if :ets.whereis(table) != :undefined, do: :ets.delete(table) end)
    %{table: table}
  end

  defp call(opts \\ []) do
    defaults = [
      plug: {Req.Test, __MODULE__},
      token: "test-token"
    ]

    Keyword.merge(defaults, opts)
  end

  defp graphql_response(body) do
    fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/graphql"
      auth = Plug.Conn.get_req_header(conn, "authorization")
      assert auth == ["bearer test-token"]

      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert {:ok, %{"query" => _, "variables" => %{"ids" => _}}} = Jason.decode(raw)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end
  end

  defp pr_node(opts) do
    %{
      "__typename" => "PullRequest",
      "id" => opts[:id],
      "number" => opts[:number],
      "state" => opts[:state] || "OPEN",
      "isDraft" => opts[:isDraft] || false,
      "baseRefName" => opts[:baseRefName] || "master",
      "headRefName" => opts[:headRefName] || "feature",
      "headRefOid" => opts[:headRefOid] || "abc123",
      "title" => opts[:title] || "test PR",
      "updatedAt" => opts[:updatedAt] || "2026-04-01T12:00:00Z",
      "closedAt" => opts[:closedAt],
      "mergedAt" => opts[:mergedAt],
      "mergeCommit" => if(opts[:mergeCommitOid], do: %{"oid" => opts[:mergeCommitOid]}),
      "labels" => opts[:labels] || %{"nodes" => []}
    }
  end

  defp rate_limit(remaining \\ 4999, reset_at \\ "2030-01-01T00:00:00Z") do
    %{"remaining" => remaining, "resetAt" => reset_at}
  end

  describe "fetch_prs/2" do
    test "returns map of node_id => PullRequest for successful response" do
      Req.Test.stub(
        __MODULE__,
        graphql_response(%{
          "data" => %{
            "rateLimit" => rate_limit(),
            "nodes" => [
              pr_node(
                id: "pr_1",
                number: 101,
                state: "OPEN",
                headRefOid: "deadbeef",
                title: "first",
                updatedAt: "2026-04-01T12:00:00Z"
              ),
              pr_node(
                id: "pr_2",
                number: 102,
                state: "MERGED",
                mergedAt: "2026-04-02T10:00:00Z",
                mergeCommitOid: "cafef00d"
              )
            ]
          }
        })
      )

      assert {:ok, result} = GraphQL.fetch_prs(["pr_1", "pr_2"], call())

      assert %PullRequest{
               node_id: "pr_1",
               number: 101,
               state: :open,
               head_sha: "deadbeef",
               title: "first",
               updated_at: ~U[2026-04-01 12:00:00Z]
             } = result["pr_1"]

      assert %PullRequest{
               node_id: "pr_2",
               number: 102,
               state: :merged,
               merged_at: ~U[2026-04-02 10:00:00Z],
               merge_commit_sha: "cafef00d"
             } = result["pr_2"]
    end

    test "maps OPEN + isDraft=true to :draft" do
      Req.Test.stub(
        __MODULE__,
        graphql_response(%{
          "data" => %{
            "rateLimit" => rate_limit(),
            "nodes" => [pr_node(id: "pr_d", number: 1, state: "OPEN", isDraft: true)]
          }
        })
      )

      assert {:ok, %{"pr_d" => %PullRequest{state: :draft}}} =
               GraphQL.fetch_prs(["pr_d"], call())
    end

    test "surfaces null nodes as :not_found without failing the batch" do
      Req.Test.stub(
        __MODULE__,
        graphql_response(%{
          "data" => %{
            "rateLimit" => rate_limit(),
            "nodes" => [
              pr_node(id: "pr_a", number: 1),
              nil,
              pr_node(id: "pr_c", number: 3)
            ]
          }
        })
      )

      assert {:ok, result} = GraphQL.fetch_prs(["pr_a", "pr_missing", "pr_c"], call())
      assert %PullRequest{node_id: "pr_a"} = result["pr_a"]
      assert result["pr_missing"] == :not_found
      assert %PullRequest{node_id: "pr_c"} = result["pr_c"]
    end

    test "extracts label names" do
      Req.Test.stub(
        __MODULE__,
        graphql_response(%{
          "data" => %{
            "rateLimit" => rate_limit(),
            "nodes" => [
              pr_node(
                id: "pr_l",
                number: 1,
                labels: %{"nodes" => [%{"name" => "bug"}, %{"name" => "10.rebuild-linux: 1"}]}
              )
            ]
          }
        })
      )

      assert {:ok, %{"pr_l" => %PullRequest{labels: ["bug", "10.rebuild-linux: 1"]}}} =
               GraphQL.fetch_prs(["pr_l"], call())
    end

    test "decodes baseRefName and headRefName onto base_ref and head_ref" do
      Req.Test.stub(
        __MODULE__,
        graphql_response(%{
          "data" => %{
            "rateLimit" => rate_limit(),
            "nodes" => [
              pr_node(
                id: "pr_refs",
                number: 1,
                baseRefName: "staging-next",
                headRefName: "topic/foo"
              )
            ]
          }
        })
      )

      assert {:ok,
              %{
                "pr_refs" => %PullRequest{
                  base_ref: "staging-next",
                  head_ref: "topic/foo"
                }
              }} =
               GraphQL.fetch_prs(["pr_refs"], call())
    end

    test "surfaces mergeCommitOid as merge_commit_sha" do
      Req.Test.stub(
        __MODULE__,
        graphql_response(%{
          "data" => %{
            "rateLimit" => rate_limit(),
            "nodes" => [
              pr_node(id: "pr_m", number: 1, state: "MERGED", mergeCommitOid: "f00dface")
            ]
          }
        })
      )

      assert {:ok, %{"pr_m" => %PullRequest{merge_commit_sha: "f00dface"}}} =
               GraphQL.fetch_prs(["pr_m"], call())
    end

    test "empty input short-circuits without HTTP" do
      Req.Test.stub(__MODULE__, fn _ -> flunk("should not make HTTP request") end)

      assert {:ok, result} = GraphQL.fetch_prs([], call())
      assert result == %{}
    end

    test "returns :too_many_ids when over 100 IDs are supplied" do
      ids = for i <- 1..101, do: "pr_#{i}"
      Req.Test.stub(__MODULE__, fn _ -> flunk("should not make HTTP request") end)

      assert {:error, :too_many_ids} = GraphQL.fetch_prs(ids, call())
    end

    test "GraphQL RATE_LIMITED error returns :rate_limited (cache left to caller)",
         %{table: table} do
      Req.Test.stub(
        __MODULE__,
        graphql_response(%{
          "data" => nil,
          "errors" => [
            %{
              "type" => "RATE_LIMITED",
              "message" => "API rate limit exceeded"
            }
          ]
        })
      )

      assert {:error, %Error{reason: :rate_limited}} =
               GraphQL.fetch_prs(["pr_x"], call(rate_limit_table: table))

      # The client does not populate the cache on rate-limit errors; callers
      # use Tracker.GitHub.seconds_until_reset(token, :graphql) to do that.
      assert :ok = RateLimitCache.check(:graphql, table)
      assert :ok = RateLimitCache.check(:rest, table)
    end

    test "HTTP 403 is treated as rate limited", %{table: table} do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 403, ~s({"message":"rate limit"}))
      end)

      assert {:error, %Error{reason: :rate_limited}} =
               GraphQL.fetch_prs(["pr_x"], call(rate_limit_table: table))

      # No rateLimit payload available, so we don't poke the cache here
      # (worker uses seconds_until_reset(:graphql) to populate it).
      assert :ok = RateLimitCache.check(:graphql, table)
    end

    test "low remaining on success updates :graphql bucket (not :rest)", %{table: table} do
      reset_at_unix = System.os_time(:second) + 1800
      reset_at = DateTime.from_unix!(reset_at_unix) |> DateTime.to_iso8601()

      Req.Test.stub(
        __MODULE__,
        graphql_response(%{
          "data" => %{
            "rateLimit" => rate_limit(50, reset_at),
            "nodes" => [pr_node(id: "pr_z", number: 1)]
          }
        })
      )

      assert {:ok, _} = GraphQL.fetch_prs(["pr_z"], call(rate_limit_table: table))

      assert {:limited, seconds} = RateLimitCache.check(:graphql, table)
      assert seconds > 0
      assert :ok = RateLimitCache.check(:rest, table)
    end

    test "high remaining on success does not touch the cache", %{table: table} do
      Req.Test.stub(
        __MODULE__,
        graphql_response(%{
          "data" => %{
            "rateLimit" => rate_limit(4999),
            "nodes" => [pr_node(id: "pr_z", number: 1)]
          }
        })
      )

      assert {:ok, _} = GraphQL.fetch_prs(["pr_z"], call(rate_limit_table: table))
      assert :ok = RateLimitCache.check(:graphql, table)
    end

    test "graphql errors with null data return {:graphql_errors, errors}" do
      Req.Test.stub(
        __MODULE__,
        graphql_response(%{
          "data" => nil,
          "errors" => [%{"type" => "NOT_FOUND", "message" => "Could not resolve"}]
        })
      )

      assert {:error, {:graphql_errors, errors}} =
               GraphQL.fetch_prs(["pr_bad"], call())

      assert [%{"type" => "NOT_FOUND"}] = errors
    end

    test "graphql errors without data key (query parse errors) return {:graphql_errors, errors}" do
      Req.Test.stub(
        __MODULE__,
        graphql_response(%{
          "errors" => [
            %{
              "message" => "Field 'bogus' doesn't exist on type 'PullRequest'",
              "extensions" => %{"code" => "undefinedField"}
            }
          ]
        })
      )

      assert {:error, {:graphql_errors, [%{"extensions" => %{"code" => "undefinedField"}}]}} =
               GraphQL.fetch_prs(["pr_bad"], call())
    end

    test "partial graphql errors with usable data still return :ok" do
      Req.Test.stub(
        __MODULE__,
        graphql_response(%{
          "data" => %{
            "rateLimit" => rate_limit(),
            "nodes" => [pr_node(id: "pr_ok", number: 1)]
          },
          "errors" => [%{"type" => "SOMETHING", "message" => "minor warning"}]
        })
      )

      assert {:ok, %{"pr_ok" => %PullRequest{}}} =
               GraphQL.fetch_prs(["pr_ok"], call())
    end

    test "server errors (5xx) return a GitHub.Error" do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 502, "Bad Gateway")
      end)

      assert {:error, %Error{code: 502}} = GraphQL.fetch_prs(["pr_x"], call())
    end
  end
end

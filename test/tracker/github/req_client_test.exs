defmodule Tracker.GitHub.ReqClientTest do
  use ExUnit.Case, async: true

  alias GitHub.Error
  alias GitHub.Operation
  alias Tracker.GitHub.ReqClient

  @s3_config %ReqClient.S3Config{
    bucket: "test-bucket",
    access_key_id: "test-key",
    secret_access_key: "test-secret",
    endpoint: "http://localhost:4444",
    region: "garage",
    plug: {Req.Test, __MODULE__}
  }

  defp build_operation(opts \\ []) do
    method = Keyword.get(opts, :method, :get)
    url = Keyword.get(opts, :url, "/repos/NixOS/nixpkgs/pulls")
    params = Keyword.get(opts, :params, state: "closed", per_page: "100")
    body = Keyword.get(opts, :body, nil)

    %Operation{
      request_method: method,
      request_url: url,
      request_params: params,
      request_body: body,
      request_server: "https://api.github.com",
      request_headers: [
        {"Authorization", "Bearer test-token"},
        {"User-Agent", "Tracker"}
      ],
      response_types: [],
      private: %{__opts__: [], __auth__: "test-token"}
    }
  end

  describe "request/2 without S3 cache" do
    test "makes GET request and populates operation response" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/repos/NixOS/nixpkgs/pulls"
        assert conn.query_string =~ "state=closed"

        conn
        |> Plug.Conn.put_resp_header("etag", ~s("abc123"))
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s([{"number": 1}]))
      end)

      operation = build_operation()

      assert {:ok, %Operation{} = result} =
               ReqClient.request(operation, plug: {Req.Test, __MODULE__})

      assert result.response_code == 200
      assert result.response_body == ~s([{"number": 1}])
    end

    test "makes POST request with body" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert conn.method == "POST"
        assert body == ~s({"permissions":{}})

        Plug.Conn.send_resp(conn, 200, ~s({"token":"inst-token"}))
      end)

      operation =
        build_operation(
          method: :post,
          url: "/app/installations/123/access_tokens",
          params: nil,
          body: ~s({"permissions":{}})
        )

      assert {:ok, %Operation{response_code: 200}} =
               ReqClient.request(operation, plug: {Req.Test, __MODULE__})
    end

    test "returns error on server error" do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 500, "Internal Server Error")
      end)

      operation = build_operation()

      assert {:error, %Error{code: 500}} =
               ReqClient.request(operation, plug: {Req.Test, __MODULE__})
    end

    test "follows redirects" do
      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/repos/NixOS/nixpkgs/pulls" ->
            conn
            |> Plug.Conn.put_resp_header("location", "https://api.github.com/redirected")
            |> Plug.Conn.send_resp(302, "")

          "/redirected" ->
            Plug.Conn.send_resp(conn, 200, ~s({"redirected": true}))
        end
      end)

      operation = build_operation()

      assert {:ok, %Operation{response_code: 200}} =
               ReqClient.request(operation, plug: {Req.Test, __MODULE__})
    end

    test "passes through 4xx responses for downstream handling" do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 403, ~s({"message":"rate limited"}))
      end)

      operation = build_operation()

      assert {:ok, %Operation{response_code: 403}} =
               ReqClient.request(operation, plug: {Req.Test, __MODULE__})
    end
  end

  describe "request/2 with S3 cache" do
    test "caches 200 response with ETag in S3" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/test-bucket/" <> _key} ->
            # Cache miss
            Plug.Conn.send_resp(conn, 404, "not found")

          {"PUT", "/test-bucket/" <> key} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:s3_put, key, body})
            Plug.Conn.send_resp(conn, 200, "")

          _ ->
            # GitHub API response
            conn
            |> Plug.Conn.put_resp_header("etag", ~s("etag-123"))
            |> Plug.Conn.send_resp(200, ~s([{"number": 1}]))
        end
      end)

      operation = build_operation()

      assert {:ok, %Operation{response_code: 200, response_body: ~s([{"number": 1}])}} =
               ReqClient.request(operation, plug: {Req.Test, __MODULE__}, s3_cache: @s3_config)

      assert_receive {:s3_put, _key, body}
      cached = Jason.decode!(body)
      assert cached["etag"] == ~s("etag-123")
      assert cached["response"] == ~s([{"number": 1}])
    end

    test "returns cached response on S3 hit with 304 from GitHub" do
      cached_data =
        Jason.encode!(%{
          etag: ~s("etag-123"),
          response: ~s([{"number": 1}]),
          headers: %{}
        })

      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/test-bucket/" <> _key} ->
            # Cache hit
            Plug.Conn.send_resp(conn, 200, cached_data)

          _ ->
            # GitHub returns 304
            assert Plug.Conn.get_req_header(conn, "if-none-match") == [~s("etag-123")]
            Plug.Conn.send_resp(conn, 304, "")
        end
      end)

      operation = build_operation()

      assert {:ok, %Operation{response_code: 200, response_body: ~s([{"number": 1}])}} =
               ReqClient.request(operation, plug: {Req.Test, __MODULE__}, s3_cache: @s3_config)
    end

    test "updates cache when GitHub returns fresh 200 despite cached ETag" do
      test_pid = self()

      cached_data =
        Jason.encode!(%{
          etag: ~s("old-etag"),
          response: ~s([{"number": 1}]),
          headers: %{}
        })

      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/test-bucket/" <> _key} ->
            Plug.Conn.send_resp(conn, 200, cached_data)

          {"PUT", "/test-bucket/" <> key} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:s3_put, key, body})
            Plug.Conn.send_resp(conn, 200, "")

          _ ->
            # GitHub returns fresh data
            conn
            |> Plug.Conn.put_resp_header("etag", ~s("new-etag"))
            |> Plug.Conn.send_resp(200, ~s([{"number": 1, "updated": true}]))
        end
      end)

      operation = build_operation()

      assert {:ok, %Operation{response_code: 200}} =
               ReqClient.request(operation, plug: {Req.Test, __MODULE__}, s3_cache: @s3_config)

      assert_receive {:s3_put, _key, body}
      cached = Jason.decode!(body)
      assert cached["etag"] == ~s("new-etag")
    end

    test "skips cache for non-GET requests" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.method == "POST"
        Plug.Conn.send_resp(conn, 200, ~s({"token":"abc"}))
      end)

      operation =
        build_operation(
          method: :post,
          url: "/app/installations/123/access_tokens",
          params: nil,
          body: ~s({})
        )

      assert {:ok, %Operation{response_code: 200}} =
               ReqClient.request(operation, plug: {Req.Test, __MODULE__}, s3_cache: @s3_config)
    end
  end

  describe "cache_key/1" do
    test "generates key from operation fields" do
      operation = build_operation()
      key = ReqClient.cache_key(operation)

      # Key includes path and hashed params + auth
      assert key =~ "github_cache/api.github.com/repos/NixOS/nixpkgs/pulls/"
      # Should have query_hash_authhash suffix (no raw params or ?)
      refute key =~ "?"
      refute key =~ "state=closed"
    end

    test "includes auth hash for isolation" do
      op1 = build_operation()
      op2 = %{op1 | private: %{op1.private | __auth__: "different-token"}}

      assert ReqClient.cache_key(op1) != ReqClient.cache_key(op2)
    end

    test "different params produce different keys" do
      op1 = build_operation(params: [state: "closed"])
      op2 = build_operation(params: [state: "open"])

      assert ReqClient.cache_key(op1) != ReqClient.cache_key(op2)
    end

    test "handles nil params" do
      operation = build_operation(params: nil)
      key = ReqClient.cache_key(operation)

      assert "github_cache/api.github.com/repos/NixOS/nixpkgs/pulls/" <> suffix = key
      # Only auth hash, no query hash
      refute suffix =~ "_"
    end
  end
end

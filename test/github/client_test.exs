defmodule GitHub.ClientTest do
  use ExUnit.Case, async: true

  alias GitHub.Client
  alias GitHub.Client.S3Config
  alias GitHub.Error

  @s3_config %S3Config{
    bucket: "test-bucket",
    access_key_id: "test-key",
    secret_access_key: "test-secret",
    endpoint: "http://localhost:4444",
    region: "garage",
    plug: {Req.Test, __MODULE__}
  }

  defp plug, do: [plug: {Req.Test, __MODULE__}]

  describe "request without S3 cache" do
    test "GET decodes the JSON body and sends auth + params" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/repos/NixOS/nixpkgs/pulls"
        assert conn.query_string =~ "state=closed"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-token"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s([{"number": 1}]))
      end)

      assert {:ok, [%{"number" => 1}]} =
               Client.get("/repos/NixOS/nixpkgs/pulls",
                 auth: "test-token",
                 params: [state: "closed"],
                 plug: {Req.Test, __MODULE__}
               )
    end

    test "POST JSON-encodes the body" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert conn.method == "POST"
        assert Jason.decode!(body) == %{"permissions" => %{}}

        Plug.Conn.send_resp(conn, 201, ~s({"token":"inst-token"}))
      end)

      assert {:ok, %{"token" => "inst-token"}} =
               Client.post("/app/installations/123/access_tokens",
                 body: %{permissions: %{}},
                 plug: {Req.Test, __MODULE__}
               )
    end

    test "5xx returns a server_error" do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 500, "Internal Server Error")
      end)

      assert {:error, %Error{code: 500, reason: :server_error}} =
               Client.get("/rate_limit", plug())
    end

    test "403 with a rate-limit message is classified as rate_limited" do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 403, ~s({"message":"API rate limit exceeded for x"}))
      end)

      assert {:error, %Error{code: 403, reason: :rate_limited}} =
               Client.get("/repos/NixOS/nixpkgs/pulls/1/files", plug())
    end

    test "403 with x-ratelimit-remaining: 0 is classified as rate_limited" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "0")
        |> Plug.Conn.send_resp(403, ~s({"message":"Forbidden"}))
      end)

      assert {:error, %Error{reason: :rate_limited}} = Client.get("/x", plug())
    end

    test "429 is classified as rate_limited" do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 429, ~s({"message":"slow down"}))
      end)

      assert {:error, %Error{reason: :rate_limited}} = Client.get("/x", plug())
    end

    test "404 is classified as not_found" do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 404, ~s({"message":"Not Found"}))
      end)

      assert {:error, %Error{code: 404, reason: :not_found}} = Client.get("/x", plug())
    end

    test "other 4xx is a generic error carrying the message" do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 422, ~s({"message":"Validation failed"}))
      end)

      assert {:error, %Error{code: 422, reason: :error, message: "Validation failed"}} =
               Client.get("/x", plug())
    end

    test "follows redirects" do
      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/start" ->
            conn
            |> Plug.Conn.put_resp_header("location", "https://api.github.com/redirected")
            |> Plug.Conn.send_resp(302, "")

          "/redirected" ->
            Plug.Conn.send_resp(conn, 200, ~s({"redirected": true}))
        end
      end)

      assert {:ok, %{"redirected" => true}} = Client.get("/start", plug())
    end
  end

  describe "request with S3 cache" do
    test "caches a 200 response carrying an ETag" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/test-bucket/" <> _key} ->
            Plug.Conn.send_resp(conn, 404, "not found")

          {"PUT", "/test-bucket/" <> key} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:s3_put, key, body})
            Plug.Conn.send_resp(conn, 200, "")

          _ ->
            conn
            |> Plug.Conn.put_resp_header("etag", ~s("etag-123"))
            |> Plug.Conn.send_resp(200, ~s([{"number": 1}]))
        end
      end)

      assert {:ok, [%{"number" => 1}]} =
               Client.get("/repos/NixOS/nixpkgs/pulls",
                 auth: "test-token",
                 plug: {Req.Test, __MODULE__},
                 s3_cache: @s3_config
               )

      assert_receive {:s3_put, _key, body}
      cached = Jason.decode!(body)
      assert cached["etag"] == ~s("etag-123")
      assert cached["response"] == ~s([{"number": 1}])
    end

    test "serves the cached body when GitHub returns 304" do
      cached_data =
        Jason.encode!(%{etag: ~s("etag-123"), response: ~s([{"number": 1}]), headers: %{}})

      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/test-bucket/" <> _key} ->
            Plug.Conn.send_resp(conn, 200, cached_data)

          _ ->
            assert Plug.Conn.get_req_header(conn, "if-none-match") == [~s("etag-123")]
            Plug.Conn.send_resp(conn, 304, "")
        end
      end)

      assert {:ok, [%{"number" => 1}]} =
               Client.get("/repos/NixOS/nixpkgs/pulls",
                 auth: "test-token",
                 plug: {Req.Test, __MODULE__},
                 s3_cache: @s3_config
               )
    end

    test "skips the cache for non-GET requests" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.method == "POST"
        Plug.Conn.send_resp(conn, 201, ~s({"token":"abc"}))
      end)

      assert {:ok, %{"token" => "abc"}} =
               Client.post("/app/installations/123/access_tokens",
                 body: %{},
                 plug: {Req.Test, __MODULE__},
                 s3_cache: @s3_config
               )
    end
  end

  describe "cache_key/4" do
    test "hashes params and auth, omitting raw values" do
      key =
        Client.cache_key(
          "https://api.github.com",
          "/repos/NixOS/nixpkgs/pulls",
          [state: "closed"],
          "tok"
        )

      assert key =~ "github_cache/api.github.com/repos/NixOS/nixpkgs/pulls/"
      refute key =~ "?"
      refute key =~ "state=closed"
    end

    test "different auth produces different keys" do
      args = ["https://api.github.com", "/x", [state: "closed"], nil]
      k1 = apply(Client, :cache_key, List.replace_at(args, 3, "tok-1"))
      k2 = apply(Client, :cache_key, List.replace_at(args, 3, "tok-2"))
      assert k1 != k2
    end

    test "different params produce different keys" do
      k1 = Client.cache_key("https://api.github.com", "/x", [state: "closed"], "tok")
      k2 = Client.cache_key("https://api.github.com", "/x", [state: "open"], "tok")
      assert k1 != k2
    end

    test "nil params yields an auth-only suffix" do
      key = Client.cache_key("https://api.github.com", "/x", nil, "tok")
      assert "github_cache/api.github.com/x/" <> suffix = key
      refute suffix =~ "_"
    end
  end
end

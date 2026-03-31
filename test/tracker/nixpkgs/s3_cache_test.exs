defmodule Tracker.Nixpkgs.S3CacheTest do
  use ExUnit.Case, async: true

  alias Tracker.Nixpkgs.S3Cache

  describe "cache_key/1" do
    test "derives key from URL mirroring host and path" do
      url =
        "https://releases.nixos.org/nixos/unstable/nixos-26.05pre969196.abc123/packages.json.br"

      assert S3Cache.cache_key(url) ==
               "cache/releases.nixos.org/nixos/unstable/nixos-26.05pre969196.abc123/packages.json.br"
    end

    test "handles git-revision path" do
      url = "https://releases.nixos.org/nixos/unstable/nixos-26.05pre969196.abc123/git-revision"

      assert S3Cache.cache_key(url) ==
               "cache/releases.nixos.org/nixos/unstable/nixos-26.05pre969196.abc123/git-revision"
    end
  end

  describe "request step" do
    setup do
      config = %S3Cache.Config{
        bucket: "test-bucket",
        access_key_id: "test-key",
        secret_access_key: "test-secret",
        endpoint: "http://localhost:4444",
        region: "garage",
        plug: {Req.Test, __MODULE__}
      }

      {:ok, config: config}
    end

    test "returns cached body on cache hit", %{config: config} do
      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/test-bucket/cache/releases.nixos.org/cached-file"} ->
            Plug.Conn.send_resp(conn, 200, "cached body")

          _ ->
            Plug.Conn.send_resp(conn, 404, "not found")
        end
      end)

      req =
        Req.new(url: "https://releases.nixos.org/cached-file")
        |> S3Cache.attach(config)

      resp = Req.get!(req)
      assert resp.body == "cached body"
    end

    test "fetches from upstream on cache miss", %{config: config} do
      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/test-bucket/" <> _} ->
            Plug.Conn.send_resp(conn, 404, "not found")

          {"PUT", "/test-bucket/" <> _} ->
            Plug.Conn.send_resp(conn, 200, "")

          _ ->
            Plug.Conn.send_resp(conn, 404, "not found")
        end
      end)

      upstream = fn conn ->
        case conn.request_path do
          "/uncached-file" ->
            Plug.Conn.send_resp(conn, 200, "upstream body")

          "/uncached-file.sha256" ->
            Plug.Conn.send_resp(conn, 404, "not found")
        end
      end

      req =
        Req.new(url: "https://releases.nixos.org/uncached-file", plug: upstream)
        |> S3Cache.attach(config)

      resp = Req.get!(req)
      assert resp.body == "upstream body"
    end

    test "verifies sha256 when sidecar exists", %{config: config} do
      body = "hello world"
      sha = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/test-bucket/" <> _} ->
            Plug.Conn.send_resp(conn, 404, "not found")

          {"PUT", "/test-bucket/" <> _} ->
            Plug.Conn.send_resp(conn, 200, "")
        end
      end)

      upstream = fn conn ->
        case conn.request_path do
          "/verified-file" ->
            Plug.Conn.send_resp(conn, 200, body)

          "/verified-file.sha256" ->
            Plug.Conn.send_resp(conn, 200, "#{sha}  verified-file")
        end
      end

      req =
        Req.new(url: "https://releases.nixos.org/verified-file", plug: upstream)
        |> S3Cache.attach(config)

      resp = Req.get!(req)
      assert resp.body == body
    end

    test "raises on sha256 mismatch", %{config: config} do
      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/test-bucket/" <> _} ->
            Plug.Conn.send_resp(conn, 404, "not found")

          {"PUT", "/test-bucket/" <> _} ->
            Plug.Conn.send_resp(conn, 200, "")
        end
      end)

      upstream = fn conn ->
        case conn.request_path do
          "/bad-file" ->
            Plug.Conn.send_resp(conn, 200, "corrupted body")

          "/bad-file.sha256" ->
            Plug.Conn.send_resp(
              conn,
              200,
              "0000000000000000000000000000000000000000000000000000000000000000  bad-file"
            )
        end
      end

      req =
        Req.new(url: "https://releases.nixos.org/bad-file", plug: upstream)
        |> S3Cache.attach(config)

      assert_raise RuntimeError, ~r/SHA-256 mismatch/, fn ->
        Req.get!(req)
      end
    end
  end
end

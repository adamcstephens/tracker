defmodule Tracker.Nixpkgs.ChangeArtifactCacheTest do
  use Tracker.DataCase, async: true

  alias Tracker.Nixpkgs.ChangeArtifactCache
  alias Tracker.Nixpkgs.S3Cache

  @attrdiff %{
    "added" => ["new-pkg"],
    "changed" => ["existing-pkg"],
    "removed" => []
  }

  defp build_comparison_zip(attrdiff \\ @attrdiff) do
    changed_paths =
      Jason.encode!(%{"attrdiff" => attrdiff, "labels" => %{}, "rebuildsByPlatform" => %{}})

    {:ok, {_, zip_body}} =
      :zip.create(~c"test.zip", [{~c"changed-paths.json", changed_paths}], [:memory])

    zip_body
  end

  defp s3_config do
    %S3Cache.Config{
      bucket: "test-bucket",
      access_key_id: "test-key",
      secret_access_key: "test-secret",
      endpoint: "http://localhost:4444",
      region: "garage",
      plug: {Req.Test, __MODULE__.S3}
    }
  end

  describe "cache_key/2" do
    test "builds key from pr_number and artifact name" do
      assert ChangeArtifactCache.cache_key(12345, "comparison") ==
               "artifacts/nixpkgs/pull_requests/12345/comparison.zip"
    end
  end

  describe "extract_attrdiff/1" do
    test "extracts attrdiff from a zip body" do
      zip_body = build_comparison_zip()
      {:ok, result} = ChangeArtifactCache.extract_attrdiff(zip_body)
      assert result == @attrdiff
    end
  end

  describe "S3 round-trip" do
    test "round-trips data through S3 via plug" do
      config = s3_config()

      store = :ets.new(:s3_store, [:set, :public])

      Req.Test.stub(__MODULE__.S3, fn conn ->
        key = conn.request_path
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        case conn.method do
          "GET" ->
            case :ets.lookup(store, key) do
              [{^key, stored_body}] -> Plug.Conn.send_resp(conn, 200, stored_body)
              [] -> Plug.Conn.send_resp(conn, 404, "not found")
            end

          "PUT" ->
            :ets.insert(store, {key, body})
            Plug.Conn.send_resp(conn, 200, "")
        end
      end)

      unique_id = System.unique_integer([:positive])
      key = ChangeArtifactCache.cache_key(unique_id, "test-artifact")

      assert :miss = S3Cache.get_object(config, key)

      body = "test artifact contents"
      assert :ok = S3Cache.put_object(config, key, body)
      assert {:ok, ^body} = S3Cache.get_object(config, key)
    end
  end

  describe "fetch_comparison/4" do
    setup do
      config = s3_config()
      Application.put_env(:tracker, :s3_cache, Map.from_struct(config))

      on_exit(fn ->
        Application.delete_env(:tracker, :s3_cache)
      end)

      {:ok, config: config}
    end

    test "returns cached attrdiff on S3 cache hit without calling GitHub", %{config: _config} do
      zip_body = build_comparison_zip()
      pr_number = System.unique_integer([:positive])
      key = ChangeArtifactCache.cache_key(pr_number, "comparison")

      # Pre-populate S3 with the cached artifact
      Req.Test.stub(__MODULE__.S3, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/test-bucket/" <> ^key} ->
            Plug.Conn.send_resp(conn, 200, zip_body)
        end
      end)

      # GitHub download stub should never be called — if it is, the test fails
      Req.Test.stub(__MODULE__.GitHub, fn _conn ->
        flunk("GitHub should not be called on cache hit")
      end)

      assert {:ok, @attrdiff} =
               ChangeArtifactCache.fetch_comparison(
                 pr_number,
                 "https://api.github.com/artifacts/download",
                 "fake-token",
                 req_options: [plug: {Req.Test, __MODULE__.GitHub}]
               )
    end

    test "downloads from GitHub on cache miss and stores in S3", %{config: _config} do
      zip_body = build_comparison_zip()
      pr_number = System.unique_integer([:positive])
      key = ChangeArtifactCache.cache_key(pr_number, "comparison")
      test_pid = self()

      store = :ets.new(:s3_store, [:set, :public])

      Req.Test.stub(__MODULE__.S3, fn conn ->
        s3_key = conn.request_path
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        case conn.method do
          "GET" ->
            case :ets.lookup(store, s3_key) do
              [{^s3_key, stored}] -> Plug.Conn.send_resp(conn, 200, stored)
              [] -> Plug.Conn.send_resp(conn, 404, "not found")
            end

          "PUT" ->
            :ets.insert(store, {s3_key, body})
            send(test_pid, {:s3_put, s3_key})
            Plug.Conn.send_resp(conn, 200, "")
        end
      end)

      Req.Test.stub(__MODULE__.GitHub, fn conn ->
        Plug.Conn.send_resp(conn, 200, zip_body)
      end)

      assert {:ok, @attrdiff} =
               ChangeArtifactCache.fetch_comparison(
                 pr_number,
                 "https://api.github.com/artifacts/download",
                 "fake-token",
                 req_options: [plug: {Req.Test, __MODULE__.GitHub}]
               )

      # Verify the artifact was stored in S3
      assert_received {:s3_put, "/test-bucket/" <> ^key}
    end

    test "returns artifact_expired when GitHub returns 410 and not cached" do
      pr_number = System.unique_integer([:positive])

      Req.Test.stub(__MODULE__.S3, fn conn ->
        Plug.Conn.send_resp(conn, 404, "not found")
      end)

      Req.Test.stub(__MODULE__.GitHub, fn conn ->
        Plug.Conn.send_resp(conn, 410, "Gone")
      end)

      assert {:error, :artifact_expired} =
               ChangeArtifactCache.fetch_comparison(
                 pr_number,
                 "https://api.github.com/artifacts/download",
                 "fake-token",
                 req_options: [plug: {Req.Test, __MODULE__.GitHub}]
               )
    end

    test "serves from cache even when artifact would be expired upstream", %{config: _config} do
      zip_body = build_comparison_zip()
      pr_number = System.unique_integer([:positive])
      key = ChangeArtifactCache.cache_key(pr_number, "comparison")

      # S3 has the cached artifact
      Req.Test.stub(__MODULE__.S3, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/test-bucket/" <> ^key} ->
            Plug.Conn.send_resp(conn, 200, zip_body)
        end
      end)

      # GitHub would return 410, but should never be called
      Req.Test.stub(__MODULE__.GitHub, fn _conn ->
        flunk("GitHub should not be called when artifact is cached")
      end)

      assert {:ok, @attrdiff} =
               ChangeArtifactCache.fetch_comparison(
                 pr_number,
                 "https://api.github.com/artifacts/download",
                 "fake-token",
                 req_options: [plug: {Req.Test, __MODULE__.GitHub}]
               )
    end
  end
end

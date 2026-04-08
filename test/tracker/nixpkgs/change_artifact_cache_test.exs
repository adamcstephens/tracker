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

  defp stub_s3_store do
    store = :ets.new(:s3_store, [:set, :public])
    test_pid = self()

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

    store
  end

  defp populate_cache(store, config, pr_number, run_id) do
    zip_body = build_comparison_zip()
    zip_key = ChangeArtifactCache.cache_key(pr_number, "comparison")
    meta_key = ChangeArtifactCache.meta_key(pr_number)

    full_zip_key = "/#{config.bucket}/#{zip_key}"
    full_meta_key = "/#{config.bucket}/#{meta_key}"

    meta = %ChangeArtifactCache.Meta{run_id: run_id}
    :ets.insert(store, {full_zip_key, zip_body})
    :ets.insert(store, {full_meta_key, :erlang.term_to_binary(meta)})

    zip_body
  end

  describe "cache_key/2" do
    test "builds key from pr_number and artifact name" do
      assert ChangeArtifactCache.cache_key(12345, "comparison") ==
               "artifacts/nixpkgs/pull_requests/12345/comparison.zip"
    end
  end

  describe "meta_key/1" do
    test "builds meta key from pr_number" do
      assert ChangeArtifactCache.meta_key(12345) ==
               "artifacts/nixpkgs/pull_requests/12345/meta.etf"
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
      _store = stub_s3_store()

      unique_id = System.unique_integer([:positive])
      key = ChangeArtifactCache.cache_key(unique_id, "test-artifact")

      assert :miss = S3Cache.get_object(config, key)

      body = "test artifact contents"
      assert :ok = S3Cache.put_object(config, key, body)
      assert {:ok, ^body} = S3Cache.get_object(config, key)
    end
  end

  describe "fetch_comparison/5" do
    setup do
      config = s3_config()
      Application.put_env(:tracker, :s3_cache, Map.from_struct(config))

      on_exit(fn ->
        Application.delete_env(:tracker, :s3_cache)
      end)

      {:ok, config: config}
    end

    test "returns cached attrdiff on cache hit with matching run_id", %{config: config} do
      pr_number = System.unique_integer([:positive])
      run_id = 99001
      store = stub_s3_store()
      populate_cache(store, config, pr_number, run_id)

      # GitHub should never be called on cache hit
      Req.Test.stub(__MODULE__.GitHub, fn _conn ->
        flunk("GitHub should not be called on cache hit")
      end)

      assert {:ok, @attrdiff} =
               ChangeArtifactCache.fetch_comparison(
                 pr_number,
                 run_id,
                 "https://api.github.com/artifacts/download",
                 "fake-token",
                 req_options: [plug: {Req.Test, __MODULE__.GitHub}]
               )
    end

    test "re-downloads when cached run_id differs from requested", %{config: config} do
      pr_number = System.unique_integer([:positive])
      old_run_id = 99001
      new_run_id = 99002
      store = stub_s3_store()
      populate_cache(store, config, pr_number, old_run_id)

      new_attrdiff = %{
        "added" => ["brand-new-pkg"],
        "changed" => [],
        "removed" => ["old-pkg"]
      }

      new_zip = build_comparison_zip(new_attrdiff)

      Req.Test.stub(__MODULE__.GitHub, fn conn ->
        Plug.Conn.send_resp(conn, 200, new_zip)
      end)

      assert {:ok, ^new_attrdiff} =
               ChangeArtifactCache.fetch_comparison(
                 pr_number,
                 new_run_id,
                 "https://api.github.com/artifacts/download",
                 "fake-token",
                 req_options: [plug: {Req.Test, __MODULE__.GitHub}]
               )

      # Verify both zip and meta were updated in S3
      zip_key = ChangeArtifactCache.cache_key(pr_number, "comparison")
      meta_key = ChangeArtifactCache.meta_key(pr_number)
      assert_received {:s3_put, "/test-bucket/" <> ^zip_key}
      assert_received {:s3_put, "/test-bucket/" <> ^meta_key}
    end

    test "downloads from GitHub on cache miss and stores zip and meta", %{config: _config} do
      zip_body = build_comparison_zip()
      pr_number = System.unique_integer([:positive])
      run_id = 99001
      _store = stub_s3_store()

      Req.Test.stub(__MODULE__.GitHub, fn conn ->
        Plug.Conn.send_resp(conn, 200, zip_body)
      end)

      assert {:ok, @attrdiff} =
               ChangeArtifactCache.fetch_comparison(
                 pr_number,
                 run_id,
                 "https://api.github.com/artifacts/download",
                 "fake-token",
                 req_options: [plug: {Req.Test, __MODULE__.GitHub}]
               )

      # Verify both zip and meta were stored in S3
      zip_key = ChangeArtifactCache.cache_key(pr_number, "comparison")
      meta_key = ChangeArtifactCache.meta_key(pr_number)
      assert_received {:s3_put, "/test-bucket/" <> ^zip_key}
      assert_received {:s3_put, "/test-bucket/" <> ^meta_key}
    end

    test "returns artifact_expired when GitHub returns 410 and not cached" do
      pr_number = System.unique_integer([:positive])
      run_id = 99001
      _store = stub_s3_store()

      Req.Test.stub(__MODULE__.GitHub, fn conn ->
        Plug.Conn.send_resp(conn, 410, "Gone")
      end)

      assert {:error, :artifact_expired} =
               ChangeArtifactCache.fetch_comparison(
                 pr_number,
                 run_id,
                 "https://api.github.com/artifacts/download",
                 "fake-token",
                 req_options: [plug: {Req.Test, __MODULE__.GitHub}]
               )
    end

    test "serves from cache even when artifact would be expired upstream", %{config: config} do
      pr_number = System.unique_integer([:positive])
      run_id = 99001
      store = stub_s3_store()
      populate_cache(store, config, pr_number, run_id)

      # GitHub would return 410, but should never be called
      Req.Test.stub(__MODULE__.GitHub, fn _conn ->
        flunk("GitHub should not be called when artifact is cached")
      end)

      assert {:ok, @attrdiff} =
               ChangeArtifactCache.fetch_comparison(
                 pr_number,
                 run_id,
                 "https://api.github.com/artifacts/download",
                 "fake-token",
                 req_options: [plug: {Req.Test, __MODULE__.GitHub}]
               )
    end
  end
end

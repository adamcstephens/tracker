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

  defp build_dummy_zip(name) do
    {:ok, {_, zip_body}} =
      :zip.create(~c"#{name}.zip", [{~c"data.txt", "contents of #{name}"}], [:memory])

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

        "DELETE" ->
          :ets.delete(store, s3_key)
          send(test_pid, {:s3_delete, s3_key})
          Plug.Conn.send_resp(conn, 204, "")
      end
    end)

    store
  end

  defp populate_cache(store, config, pr_number, run_id, artifact_names) do
    for name <- artifact_names do
      zip_body =
        if name == "comparison", do: build_comparison_zip(), else: build_dummy_zip(name)

      zip_key = ChangeArtifactCache.cache_key(pr_number, name)
      full_zip_key = "/#{config.bucket}/#{zip_key}"
      :ets.insert(store, {full_zip_key, zip_body})
    end

    meta_key = ChangeArtifactCache.meta_key(pr_number)
    full_meta_key = "/#{config.bucket}/#{meta_key}"
    meta = %ChangeArtifactCache.Meta{run_id: run_id, names: artifact_names}
    :ets.insert(store, {full_meta_key, :erlang.term_to_binary(meta)})
  end

  defp fake_artifacts(names) do
    Enum.map(names, fn name ->
      %{name: name, archive_download_url: "https://api.github.com/artifacts/#{name}/download"}
    end)
  end

  @all_artifact_names ~w(comparison diff-aarch64-darwin diff-aarch64-linux diff-x86_64-darwin diff-x86_64-linux maintainers)

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

  describe "cache_run_artifacts/5" do
    setup do
      config = s3_config()
      Application.put_env(:tracker, :s3_cache, Map.from_struct(config))

      on_exit(fn ->
        Application.delete_env(:tracker, :s3_cache)
      end)

      {:ok, config: config}
    end

    test "downloads and caches all artifacts on cache miss", %{config: _config} do
      pr_number = System.unique_integer([:positive])
      run_id = 99001
      _store = stub_s3_store()
      artifacts = fake_artifacts(@all_artifact_names)

      zips =
        Map.new(@all_artifact_names, fn name ->
          {name,
           if(name == "comparison", do: build_comparison_zip(), else: build_dummy_zip(name))}
        end)

      Req.Test.stub(__MODULE__.GitHub, fn conn ->
        # Extract artifact name from URL
        name = conn.request_path |> String.split("/") |> Enum.at(-2)
        Plug.Conn.send_resp(conn, 200, zips[name])
      end)

      assert :ok =
               ChangeArtifactCache.cache_run_artifacts(
                 pr_number,
                 run_id,
                 artifacts,
                 "fake-token",
                 req_options: [plug: {Req.Test, __MODULE__.GitHub}]
               )

      # Verify all artifacts + meta were stored
      for name <- @all_artifact_names do
        key = ChangeArtifactCache.cache_key(pr_number, name)
        assert_received {:s3_put, "/test-bucket/" <> ^key}
      end

      meta_key = ChangeArtifactCache.meta_key(pr_number)
      assert_received {:s3_put, "/test-bucket/" <> ^meta_key}
    end

    test "skips download when run_id matches cached meta", %{config: config} do
      pr_number = System.unique_integer([:positive])
      run_id = 99001
      store = stub_s3_store()
      populate_cache(store, config, pr_number, run_id, @all_artifact_names)
      artifacts = fake_artifacts(@all_artifact_names)

      Req.Test.stub(__MODULE__.GitHub, fn _conn ->
        flunk("GitHub should not be called when all artifacts are cached")
      end)

      assert :ok =
               ChangeArtifactCache.cache_run_artifacts(
                 pr_number,
                 run_id,
                 artifacts,
                 "fake-token",
                 req_options: [plug: {Req.Test, __MODULE__.GitHub}]
               )
    end

    test "re-downloads all artifacts when run_id differs", %{config: config} do
      pr_number = System.unique_integer([:positive])
      old_run_id = 99001
      new_run_id = 99002
      store = stub_s3_store()
      populate_cache(store, config, pr_number, old_run_id, @all_artifact_names)
      artifacts = fake_artifacts(@all_artifact_names)

      Req.Test.stub(__MODULE__.GitHub, fn conn ->
        name = conn.request_path |> String.split("/") |> Enum.at(-2)
        zip = if(name == "comparison", do: build_comparison_zip(), else: build_dummy_zip(name))
        Plug.Conn.send_resp(conn, 200, zip)
      end)

      assert :ok =
               ChangeArtifactCache.cache_run_artifacts(
                 pr_number,
                 new_run_id,
                 artifacts,
                 "fake-token",
                 req_options: [plug: {Req.Test, __MODULE__.GitHub}]
               )

      # All artifacts should be re-stored
      for name <- @all_artifact_names do
        key = ChangeArtifactCache.cache_key(pr_number, name)
        assert_received {:s3_put, "/test-bucket/" <> ^key}
      end
    end

    test "returns artifact_expired when GitHub returns 410" do
      pr_number = System.unique_integer([:positive])
      run_id = 99001
      _store = stub_s3_store()
      artifacts = fake_artifacts(@all_artifact_names)

      Req.Test.stub(__MODULE__.GitHub, fn conn ->
        Plug.Conn.send_resp(conn, 410, "Gone")
      end)

      assert {:error, :artifact_expired} =
               ChangeArtifactCache.cache_run_artifacts(
                 pr_number,
                 run_id,
                 artifacts,
                 "fake-token",
                 req_options: [plug: {Req.Test, __MODULE__.GitHub}]
               )
    end
  end

  describe "read_artifact/2" do
    setup do
      config = s3_config()
      Application.put_env(:tracker, :s3_cache, Map.from_struct(config))

      on_exit(fn ->
        Application.delete_env(:tracker, :s3_cache)
      end)

      {:ok, config: config}
    end

    test "reads a cached artifact zip from S3", %{config: config} do
      pr_number = System.unique_integer([:positive])
      store = stub_s3_store()
      zip_body = build_comparison_zip()
      zip_key = ChangeArtifactCache.cache_key(pr_number, "comparison")
      :ets.insert(store, {"/#{config.bucket}/#{zip_key}", zip_body})

      assert {:ok, ^zip_body} = ChangeArtifactCache.read_artifact(pr_number, "comparison")
    end

    test "returns :miss when artifact is not cached" do
      pr_number = System.unique_integer([:positive])
      _store = stub_s3_store()

      assert :miss = ChangeArtifactCache.read_artifact(pr_number, "comparison")
    end
  end

  describe "invalidate_meta/1" do
    setup do
      config = s3_config()
      Application.put_env(:tracker, :s3_cache, Map.from_struct(config))

      on_exit(fn ->
        Application.delete_env(:tracker, :s3_cache)
      end)

      {:ok, config: config}
    end

    test "deletes the meta from S3 so the next cache_run_artifacts re-downloads",
         %{config: config} do
      pr_number = System.unique_integer([:positive])
      store = stub_s3_store()
      populate_cache(store, config, pr_number, 99001, @all_artifact_names)

      assert :ok = ChangeArtifactCache.invalidate_meta(pr_number)

      meta_key = ChangeArtifactCache.meta_key(pr_number)
      assert_received {:s3_delete, "/test-bucket/" <> ^meta_key}

      # Meta should be gone
      assert :miss = S3Cache.get_object(config, meta_key)
    end

    test "returns :ok when meta does not exist" do
      pr_number = System.unique_integer([:positive])
      _store = stub_s3_store()

      assert :ok = ChangeArtifactCache.invalidate_meta(pr_number)
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

    test "extracts attrdiff from cached comparison artifact", %{config: config} do
      pr_number = System.unique_integer([:positive])
      store = stub_s3_store()
      zip_body = build_comparison_zip()
      zip_key = ChangeArtifactCache.cache_key(pr_number, "comparison")
      :ets.insert(store, {"/#{config.bucket}/#{zip_key}", zip_body})

      assert {:ok, @attrdiff} = ChangeArtifactCache.fetch_comparison(pr_number)
    end

    test "returns error when comparison is not cached" do
      pr_number = System.unique_integer([:positive])
      _store = stub_s3_store()

      assert {:error, :not_cached} = ChangeArtifactCache.fetch_comparison(pr_number)
    end

    test "returns descriptive error when meta exists but comparison artifact is missing",
         %{config: config} do
      pr_number = System.unique_integer([:positive])
      store = stub_s3_store()
      # Populate cache with non-comparison artifacts only
      populate_cache(store, config, pr_number, 99001, ["diff-aarch64-linux", "diff-x86_64-linux"])

      assert {:error, {:comparison_not_in_run, ["diff-aarch64-linux", "diff-x86_64-linux"]}} =
               ChangeArtifactCache.fetch_comparison(pr_number)
    end

    test "rejects PR-sourced cache when merged read is expected", %{config: config} do
      pr_number = System.unique_integer([:positive])
      store = stub_s3_store()
      zip_body = build_comparison_zip()
      zip_key = ChangeArtifactCache.cache_key(pr_number, "comparison")
      :ets.insert(store, {"/#{config.bucket}/#{zip_key}", zip_body})

      meta = %ChangeArtifactCache.Meta{run_id: 1, names: ["comparison"], source: :pr}
      meta_key = ChangeArtifactCache.meta_key(pr_number)
      :ets.insert(store, {"/#{config.bucket}/#{meta_key}", :erlang.term_to_binary(meta)})

      assert {:error, {:source_mismatch, :pr}} =
               ChangeArtifactCache.fetch_comparison(pr_number, expected_source: :merge_group)

      # Without the constraint, the cache still serves the artifact.
      assert {:ok, @attrdiff} = ChangeArtifactCache.fetch_comparison(pr_number)
    end

    test "legacy meta with no :source field grandfathers to :merge_group", %{config: config} do
      pr_number = System.unique_integer([:positive])
      store = stub_s3_store()
      zip_body = build_comparison_zip()
      zip_key = ChangeArtifactCache.cache_key(pr_number, "comparison")
      :ets.insert(store, {"/#{config.bucket}/#{zip_key}", zip_body})

      # Simulate a meta serialized before :source existed — a struct with
      # the field absent. Deliberately constructing via Map.delete so
      # binary_to_term produces a key-less term.
      legacy_meta =
        Map.delete(%ChangeArtifactCache.Meta{run_id: 1, names: ["comparison"]}, :source)

      meta_key = ChangeArtifactCache.meta_key(pr_number)
      :ets.insert(store, {"/#{config.bucket}/#{meta_key}", :erlang.term_to_binary(legacy_meta)})

      assert {:ok, @attrdiff} =
               ChangeArtifactCache.fetch_comparison(pr_number, expected_source: :merge_group)

      assert {:error, {:source_mismatch, :merge_group}} =
               ChangeArtifactCache.fetch_comparison(pr_number, expected_source: :pr)
    end

    test "merge-group-sourced cache satisfies a merged read", %{config: config} do
      pr_number = System.unique_integer([:positive])
      store = stub_s3_store()
      zip_body = build_comparison_zip()
      zip_key = ChangeArtifactCache.cache_key(pr_number, "comparison")
      :ets.insert(store, {"/#{config.bucket}/#{zip_key}", zip_body})

      meta = %ChangeArtifactCache.Meta{run_id: 1, names: ["comparison"], source: :merge_group}
      meta_key = ChangeArtifactCache.meta_key(pr_number)
      :ets.insert(store, {"/#{config.bucket}/#{meta_key}", :erlang.term_to_binary(meta)})

      assert {:ok, @attrdiff} =
               ChangeArtifactCache.fetch_comparison(pr_number, expected_source: :merge_group)
    end
  end
end

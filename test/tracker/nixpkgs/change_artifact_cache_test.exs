defmodule Tracker.Nixpkgs.ChangeArtifactCacheTest do
  use Tracker.DataCase, async: true

  alias Tracker.Nixpkgs.ChangeArtifactCache

  describe "cache_key/2" do
    test "builds key from run_id and artifact name" do
      assert ChangeArtifactCache.cache_key(12345, "comparison") ==
               "artifacts/nixpkgs/pull_requests/12345/comparison.zip"
    end
  end

  describe "get/3 and put/3" do
    setup do
      config = Tracker.Nixpkgs.S3Cache.config()

      if is_nil(config) do
        {:ok, skip: true}
      else
        {:ok, config: config}
      end
    end

    @tag :s3
    test "round-trips data through S3", %{config: config} = context do
      if context[:skip], do: flunk("S3 not configured")

      unique_id = System.unique_integer([:positive])
      key = ChangeArtifactCache.cache_key(unique_id, "test-artifact")

      assert :miss = Tracker.Nixpkgs.S3Cache.get_object(config, key)

      body = "test artifact contents"
      assert :ok = Tracker.Nixpkgs.S3Cache.put_object(config, key, body)
      assert {:ok, ^body} = Tracker.Nixpkgs.S3Cache.get_object(config, key)
    end
  end

  describe "fetch_comparison/3" do
    test "extracts attrdiff from a zip body" do
      attrdiff = %{
        "added" => ["new-pkg"],
        "changed" => ["existing-pkg"],
        "removed" => []
      }

      changed_paths =
        Jason.encode!(%{"attrdiff" => attrdiff, "labels" => %{}, "rebuildsByPlatform" => %{}})

      {:ok, {_, zip_body}} =
        :zip.create(~c"test.zip", [{~c"changed-paths.json", changed_paths}], [:memory])

      {:ok, result} = Tracker.Nixpkgs.ChangeArtifactCache.extract_attrdiff(zip_body)
      assert result == attrdiff
    end
  end
end

defmodule Tracker.Nixpkgs.ChangeArtifactCache do
  @moduledoc """
  Pull-through S3 cache for GitHub Actions artifacts.

  Checks S3 first for a cached artifact zip, falls back to downloading
  from GitHub, and stores in S3 on cache miss. This provides durable
  storage past GitHub's 90-day artifact expiry.
  """

  use TypedStruct

  require Logger

  alias Tracker.Nixpkgs.S3Cache

  # Meta should always be read forward
  # avoid breaking changes, or upcast on read
  defmodule Meta do
    use TypedStruct

    typedstruct enforce: true do
      field :version, integer(), default: 1
      field :run_id, integer()
      field :names, [String.t()], default: []
      # Workflow that produced the cached artifacts. `:merge_group` is the
      # post-merge canonical comparison; `:pr` is the in-flight PR-run
      # comparison and should not satisfy reads expecting `:merge_group`.
      field :source, :merge_group | :pr, default: :merge_group
    end
  end

  @doc """
  Builds the S3 key for an artifact.

  ## Examples

      iex> ChangeArtifactCache.cache_key(12345, "comparison")
      "artifacts/nixpkgs/pull_requests/12345/comparison.zip"
  """
  def cache_key(pr_number, artifact_name) do
    "artifacts/nixpkgs/pull_requests/#{pr_number}/#{artifact_name}.zip"
  end

  @doc """
  Builds the S3 key for artifact metadata.

  ## Examples

      iex> ChangeArtifactCache.meta_key(12345)
      "artifacts/nixpkgs/pull_requests/12345/meta.etf"
  """
  def meta_key(pr_number) do
    "artifacts/nixpkgs/pull_requests/#{pr_number}/meta.etf"
  end

  @doc """
  Caches all artifacts from a workflow run in S3.

  Checks the meta.etf sidecar first — if the cached run_id matches,
  all artifacts are assumed present and no downloads occur. On a miss
  or run_id mismatch, downloads and stores every artifact, then writes
  updated metadata.

  Each artifact map must have `:name` and `:archive_download_url` keys.

  Options:
    * `:source` — `:merge_group` (default) or `:pr`. Records which
      workflow produced these artifacts so that `fetch_comparison/2`
      can reject a cache hit from the wrong source.

  Returns `:ok` or `{:error, reason}` (stops on first download failure).
  """
  def cache_run_artifacts(pr_number, run_id, artifacts, token, opts \\ []) do
    m_key = meta_key(pr_number)
    source = Keyword.get(opts, :source, :merge_group)

    if run_cached?(m_key, run_id) do
      Logger.debug("All artifacts cached for PR ##{pr_number}, run #{run_id}")
      :ok
    else
      Logger.debug("Caching #{length(artifacts)} artifacts for PR ##{pr_number}, run #{run_id}")

      names = Enum.map(artifacts, & &1.name)

      case download_and_store_all(pr_number, artifacts, token, opts) do
        :ok ->
          store_meta(m_key, %Meta{run_id: run_id, names: names, source: source})
          :ok

        {:error, _} = error ->
          error
      end
    end
  end

  @doc """
  Deletes the meta sidecar for a PR, forcing the next `cache_run_artifacts`
  call to re-download and re-cache all artifacts.

  Returns `:ok`.
  """
  def invalidate_meta(pr_number) do
    key = meta_key(pr_number)

    case S3Cache.config() do
      nil -> :ok
      config -> S3Cache.delete_object(config, key)
    end

    :ok
  end

  @doc """
  Reads a single cached artifact zip from S3.

  Returns `{:ok, zip_body}` or `:miss`.
  """
  def read_artifact(pr_number, artifact_name) do
    key = cache_key(pr_number, artifact_name)

    case S3Cache.config() do
      nil -> :miss
      config -> S3Cache.get_object(config, key)
    end
  end

  @doc """
  Reads the cached comparison artifact and extracts its attrdiff.

  Options:
    * `:expected_source` — when set, the cached `Meta.source` must match
      or the read returns `{:error, {:source_mismatch, cached}}`. Used
      to keep a PR-run cache from satisfying a merged read.

  Returns `{:ok, attrdiff}` or `{:error, reason}`.
  """
  def fetch_comparison(pr_number, opts \\ []) do
    expected = Keyword.get(opts, :expected_source)

    with :ok <- check_source(pr_number, expected),
         {:ok, zip_body} <- read_or_miss(pr_number) do
      extract_attrdiff(zip_body)
    end
  end

  defp check_source(_pr_number, nil), do: :ok

  defp check_source(pr_number, expected) do
    case read_meta(pr_number) do
      {:ok, meta} ->
        # Pre-trk-185 metas were serialized without :source; grandfather
        # them in as :merge_group since that was the only path then.
        cached = Map.get(meta, :source) || :merge_group

        if cached == expected, do: :ok, else: {:error, {:source_mismatch, cached}}

      :miss ->
        :ok
    end
  end

  defp read_or_miss(pr_number) do
    case read_artifact(pr_number, "comparison") do
      {:ok, zip_body} ->
        {:ok, zip_body}

      :miss ->
        case read_meta(pr_number) do
          {:ok, %Meta{names: names}} when names != [] ->
            {:error, {:comparison_not_in_run, names}}

          _ ->
            {:error, :not_cached}
        end
    end
  end

  @doc """
  Extracts attrdiff from a zip body containing changed-paths.json.
  """
  def extract_attrdiff(zip_body) do
    case :zip.extract(zip_body, [:memory]) do
      {:ok, files} ->
        case List.keyfind(files, ~c"changed-paths.json", 0) do
          {_, contents} ->
            case Jason.decode(contents) do
              {:ok, %{"attrdiff" => attrdiff}} ->
                {:ok, attrdiff}

              {:ok, _} ->
                {:error, "changed-paths.json missing attrdiff key"}

              {:error, reason} ->
                {:error, "Failed to parse changed-paths.json: #{inspect(reason)}"}
            end

          nil ->
            {:error, "changed-paths.json not found in comparison artifact"}
        end

      {:error, reason} ->
        {:error, "Failed to extract zip: #{inspect(reason)}"}
    end
  end

  defp read_meta(pr_number) do
    key = meta_key(pr_number)

    case S3Cache.config() do
      nil ->
        :miss

      config ->
        case S3Cache.get_object(config, key) do
          {:ok, meta_binary} -> {:ok, :erlang.binary_to_term(meta_binary)}
          :miss -> :miss
        end
    end
  end

  defp run_cached?(meta_key, run_id) do
    case S3Cache.config() do
      nil ->
        false

      config ->
        case S3Cache.get_object(config, meta_key) do
          {:ok, meta_binary} ->
            %Meta{run_id: cached_run_id} = :erlang.binary_to_term(meta_binary)
            cached_run_id == run_id

          :miss ->
            false
        end
    end
  end

  defp download_and_store_all(pr_number, artifacts, token, opts) do
    Enum.reduce_while(artifacts, :ok, fn artifact, :ok ->
      key = cache_key(pr_number, artifact.name)

      case download_artifact(artifact.archive_download_url, token, opts) do
        {:ok, zip_body} ->
          store_in_cache(key, zip_body)
          {:cont, :ok}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp store_in_cache(key, body) do
    case S3Cache.config() do
      nil -> :ok
      config -> S3Cache.put_object(config, key, body)
    end
  end

  defp store_meta(key, %Meta{} = meta) do
    case S3Cache.config() do
      nil -> :ok
      config -> S3Cache.put_object(config, key, :erlang.term_to_binary(meta))
    end
  end

  defp download_artifact(archive_url, token, opts) do
    req_options = Keyword.get(opts, :req_options, [])

    case Req.get(
           archive_url,
           [
             {:headers, %{"authorization" => "bearer #{token}", "user-agent" => "Tracker"}},
             {:redirect, true},
             {:decode_body, false}
             | req_options
           ]
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: 410}} -> {:error, :artifact_expired}
      {:ok, %{status: status}} -> {:error, "Artifact download failed with status #{status}"}
      {:error, reason} -> {:error, reason}
    end
  end
end

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

  defmodule Meta do
    use TypedStruct

    typedstruct enforce: true do
      field :version, integer(), default: 1
      field :run_id, integer()
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
  Fetches a comparison artifact's attrdiff, using S3 as a pull-through cache.

  Returns `{:ok, attrdiff}` or `{:error, reason}`.
  """
  def fetch_comparison(pr_number, run_id, archive_download_url, token, opts \\ []) do
    zip_key = cache_key(pr_number, "comparison")
    m_key = meta_key(pr_number)

    case try_cache_with_meta(zip_key, m_key, run_id) do
      {:ok, zip_body} ->
        Logger.debug("Artifact cache hit for PR ##{pr_number}")
        extract_attrdiff(zip_body)

      :miss ->
        Logger.debug("Artifact cache miss for PR ##{pr_number}, downloading")

        with {:ok, zip_body} <- download_artifact(archive_download_url, token, opts) do
          store_in_cache(zip_key, zip_body)
          store_meta(m_key, %Meta{run_id: run_id})
          extract_attrdiff(zip_body)
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

  defp try_cache_with_meta(zip_key, meta_key, run_id) do
    case S3Cache.config() do
      nil ->
        :miss

      config ->
        case S3Cache.get_object(config, meta_key) do
          {:ok, meta_binary} ->
            %Meta{run_id: cached_run_id} = :erlang.binary_to_term(meta_binary)

            if cached_run_id == run_id do
              S3Cache.get_object(config, zip_key)
            else
              :miss
            end

          :miss ->
            :miss
        end
    end
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

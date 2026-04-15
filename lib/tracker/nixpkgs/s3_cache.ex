defmodule Tracker.Nixpkgs.S3Cache do
  @moduledoc """
  S3 write-through cache for releases.nixos.org responses.

  Caches raw response bodies in an S3-compatible bucket (Garage) with keys
  that mirror the upstream URL structure under a `cache/` prefix.

  Optionally verifies SHA-256 integrity using `.sha256` sidecar files from
  the upstream CDN.
  """

  require Logger

  use TypedStruct

  defmodule Config do
    use TypedStruct

    typedstruct enforce: true do
      field :bucket, String.t()
      field :access_key_id, String.t()
      field :secret_access_key, String.t()
      field :endpoint, String.t()
      field :region, String.t()
      field :plug, term(), enforce: false
    end
  end

  @doc """
  Derives the S3 cache key from an upstream URL.

  Mirrors the host and path under a `cache/` prefix.

  ## Examples

      iex> S3Cache.cache_key("https://releases.nixos.org/nixos/unstable/rev123/packages.json.br")
      "cache/releases.nixos.org/nixos/unstable/rev123/packages.json.br"
  """
  def cache_key(url) when is_binary(url) do
    uri = URI.parse(url)
    "cache/#{uri.host}#{uri.path}"
  end

  @doc """
  Returns the S3Cache config from application environment, or nil if not configured.
  """
  def config do
    case Application.get_env(:tracker, :s3_cache) do
      nil -> nil
      opts -> struct!(Config, opts)
    end
  end

  @doc """
  Creates a new Req request with the S3 cache step attached, if configured.

  Returns a plain `Req.new()` if no S3 cache config is present.
  """
  def new do
    req = Req.new()

    case config() do
      nil -> req
      config -> attach(req, config)
    end
  end

  @doc """
  Attaches the S3 cache request and response steps to a Req request.
  """
  def attach(%Req.Request{} = request, %Config{} = config) do
    request
    |> Req.Request.register_options([:s3_cache_config, :s3_cache_hit])
    |> Req.Request.merge_options(s3_cache_config: config)
    |> Req.Request.prepend_request_steps(s3_cache_check: &check_cache/1)
    |> Req.Request.append_response_steps(s3_cache_write: &write_cache/1)
  end

  defp check_cache(request) do
    config = request.options[:s3_cache_config]

    if config && request.options[:cache] != false do
      url = URI.to_string(request.url)
      key = cache_key(url)

      case get_object(config, key) do
        {:ok, body} ->
          response = %Req.Response{status: 200, body: body}
          request = Req.Request.merge_options(request, s3_cache_hit: true)
          {request, response}

        :miss ->
          request
      end
    else
      request
    end
  end

  defp write_cache({request, response}) do
    config = request.options[:s3_cache_config]

    if config && response.status == 200 && request.options[:cache] != false &&
         !request.options[:s3_cache_hit] do
      url = URI.to_string(request.url)
      key = cache_key(url)
      maybe_verify_and_store(config, request, url, key, response.body)
    end

    {request, response}
  end

  defp maybe_verify_and_store(config, request, url, key, body) do
    case fetch_sha256(request, url) do
      {:ok, expected_hash, sidecar_body} ->
        actual_hash = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

        if actual_hash == expected_hash do
          put_object(config, key, body)
          sidecar_key = key <> ".sha256"
          put_object(config, sidecar_key, sidecar_body)
        else
          raise "SHA-256 mismatch for #{url}: expected #{expected_hash}, got #{actual_hash}"
        end

      :no_sidecar ->
        put_object(config, key, body)
    end
  end

  defp fetch_sha256(request, url) do
    sidecar_url = url <> ".sha256"

    # Build a minimal request that inherits the upstream plug (for testing)
    sidecar_opts =
      if request.options[:plug] do
        [plug: request.options[:plug], retry: false]
      else
        [retry: false]
      end

    case Req.get(sidecar_url, sidecar_opts) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        hash = body |> String.trim() |> String.split(~r/\s+/) |> List.first()
        {:ok, hash, body}

      _ ->
        :no_sidecar
    end
  end

  @doc """
  Builds a Req request configured for S3 access.
  """
  def s3_req(config) do
    req = Req.new()

    if config.plug do
      Req.merge(req, plug: config.plug)
    else
      req
      |> ReqS3.attach(
        aws_sigv4: [
          access_key_id: config.access_key_id,
          secret_access_key: config.secret_access_key,
          region: config.region
        ],
        aws_endpoint_url_s3: config.endpoint
      )
    end
  end

  @doc """
  Builds the S3 URL for a given key.
  """
  def s3_url(config, key) do
    if config.plug do
      "/#{config.bucket}/#{key}"
    else
      "s3://#{config.bucket}/#{key}"
    end
  end

  @doc """
  Gets an object from S3. Returns `{:ok, body}` or `:miss`.
  """
  def get_object(config, key) do
    req = s3_req(config)
    url = s3_url(config, key)

    case Req.get(req, url: url, decode_body: false, retry: false) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      _ ->
        :miss
    end
  end

  @doc """
  Deletes an object from S3. Returns `:ok` or `:error`.
  """
  def delete_object(config, key) do
    req = s3_req(config)
    url = s3_url(config, key)

    case Req.delete(req, url: url) do
      {:ok, %Req.Response{status: status}} when status in [200, 204] ->
        :ok

      {:ok, %Req.Response{status: status, body: resp_body}} ->
        Logger.error(
          "Failed to delete S3 object #{key}: status #{status}, body: #{inspect(resp_body)}"
        )

        :error

      {:error, reason} ->
        Logger.error("Failed to delete S3 object #{key}: #{inspect(reason)}")
        :error
    end
  end

  @doc """
  Puts an object into S3. Returns `:ok` or `:error`.
  """
  def put_object(config, key, body) do
    req = s3_req(config)
    url = s3_url(config, key)

    case Req.put(req, url: url, body: body) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status, body: resp_body}} ->
        Logger.error(
          "Failed to write S3 cache #{key}: status #{status}, body: #{inspect(resp_body)}"
        )

        :error

      {:error, reason} ->
        Logger.error("Failed to write S3 cache #{key}: #{inspect(reason)}")
        :error
    end
  end
end

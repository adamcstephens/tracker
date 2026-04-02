defmodule Tracker.GitHub.ReqClient do
  @moduledoc """
  Req-based HTTP client plugin for oapi_github with S3 ETag caching.

  Replaces the default HTTPoison client in the oapi_github plugin stack.
  When S3 cache config is provided, GET requests are cached using ETags
  for conditional requests — 304 responses from GitHub are free against
  rate limits.
  """

  require Logger

  alias GitHub.Error
  alias GitHub.Operation

  use TypedStruct

  defmodule S3Config do
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

  @http_code_success 200..206
  @http_code_server_error 500..511

  @doc """
  Returns the S3 cache config from application environment, or nil if not configured.
  """
  def s3_config do
    case Application.get_env(:tracker, :github_s3_cache) do
      nil -> nil
      opts -> struct!(S3Config, opts)
    end
  end

  @doc """
  oapi_github plugin function that executes HTTP requests via Req.

  Accepts the following options (via plugin opts or operation opts):

    * `:plug` — Req test plug for stubbing (testing only)
    * `:s3_cache` — `%S3Config{}` to enable S3 ETag caching (overrides app config)
  """
  @spec request(Operation.t(), keyword) :: {:ok, Operation.t()} | {:error, Error.t()}
  def request(
        %Operation{
          request_body: body,
          request_headers: headers,
          request_method: method,
          request_params: params,
          request_server: server,
          request_url: url
        } = operation,
        opts
      ) do
    merged_opts = Keyword.merge(opts, Map.get(operation.private, :__opts__, []))
    s3_config = merged_opts[:s3_cache] || s3_config()
    plug = merged_opts[:plug]

    full_url = Path.join(server, url)

    req_headers =
      Enum.map(headers, fn {k, v} -> {String.downcase(k), v} end)

    {cached_entry, req_headers} =
      if s3_config && method == :get do
        maybe_add_etag(operation, s3_config, req_headers)
      else
        {nil, req_headers}
      end

    req_opts =
      [
        method: method,
        url: full_url,
        headers: req_headers,
        decode_body: false,
        redirect: true,
        retry: false
      ]
      |> maybe_add_body(body)
      |> maybe_add_params(params)
      |> maybe_add_plug(plug)

    case Req.request(Req.new(), req_opts) do
      {:ok, %Req.Response{} = response} ->
        process_response(operation, response, s3_config, cached_entry)

      {:error, reason} ->
        message = "Error during HTTP request"
        step = {__MODULE__, :request}
        {:error, Error.new(message: message, operation: operation, source: reason, step: step)}
    end
  end

  defp maybe_add_body(opts, nil), do: opts
  defp maybe_add_body(opts, ""), do: opts
  defp maybe_add_body(opts, body), do: Keyword.put(opts, :body, body)

  defp maybe_add_params(opts, nil), do: opts
  defp maybe_add_params(opts, []), do: opts
  defp maybe_add_params(opts, params), do: Keyword.put(opts, :params, params)

  defp maybe_add_plug(opts, nil), do: opts
  defp maybe_add_plug(opts, plug), do: Keyword.put(opts, :plug, plug)

  defp process_response(%Operation{} = operation, %Req.Response{status: 304}, _s3_config, cached_entry)
       when not is_nil(cached_entry) do
    # 304 Not Modified — use cached response body (free, no rate limit hit)
    cached_headers =
      case cached_entry["headers"] do
        headers when is_map(headers) ->
          Enum.map(headers, fn {k, v} ->
            value = if is_list(v), do: Enum.join(v, ", "), else: v
            {k, value}
          end)

        _ ->
          [{"content-type", "application/json; charset=utf-8"}]
      end

    operation = %Operation{
      operation
      | response_body: cached_entry["response"],
        response_code: 200,
        response_headers: cached_headers
    }

    {:ok, operation}
  end

  defp process_response(%Operation{} = operation, %Req.Response{status: status} = response, _s3_config, _cached)
       when status in @http_code_server_error do
    message = "Received server error response (#{status})"
    step = {__MODULE__, :request}

    {:error,
     Error.new(
       code: status,
       message: message,
       operation: operation,
       source: response.body,
       step: step
     )}
  end

  defp process_response(%Operation{} = operation, %Req.Response{} = response, s3_config, _cached) do
    headers =
      Enum.map(response.headers, fn {k, v} ->
        {k, if(is_list(v), do: Enum.join(v, ", "), else: v)}
      end)

    operation = %Operation{
      operation
      | response_body: response.body,
        response_code: response.status,
        response_headers: headers
    }

    if s3_config && response.status in @http_code_success && operation.request_method == :get do
      maybe_cache_response(operation, response, s3_config)
    end

    {:ok, operation}
  end

  # S3 Cache Logic

  defp maybe_add_etag(operation, s3_config, headers) do
    key = cache_key(operation)

    case get_object(s3_config, key) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"etag" => etag} = entry} ->
            headers = [{"if-none-match", etag} | headers]
            {entry, headers}

          _ ->
            {nil, headers}
        end

      :miss ->
        {nil, headers}
    end
  end

  defp maybe_cache_response(operation, response, s3_config) do
    etag = Req.Response.get_header(response, "etag") |> List.first()

    if etag do
      key = cache_key(operation)

      cache_entry =
        Jason.encode!(%{
          etag: etag,
          response: response.body,
          headers: Map.new(response.headers)
        })

      put_object(s3_config, key, cache_entry)
    end
  end

  @doc """
  Generates the S3 cache key for an operation.

  Format: `github_cache/{server}/{path}?{sorted_params}:{auth_hash}`
  """
  def cache_key(%Operation{} = operation) do
    %Operation{
      request_server: server,
      request_url: url,
      request_params: params,
      private: private
    } = operation

    host = URI.parse(server).host

    query_hash =
      if params && params != [] do
        params
        |> Enum.sort_by(fn {k, _} -> to_string(k) end)
        |> URI.encode_query()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)
        |> binary_part(0, 12)
      end

    auth_hash =
      case private[:__auth__] do
        nil ->
          "anon"

        auth ->
          :crypto.hash(:sha256, to_string(auth))
          |> Base.encode16(case: :lower)
          |> binary_part(0, 12)
      end

    suffix =
      case query_hash do
        nil -> auth_hash
        qh -> "#{qh}_#{auth_hash}"
      end

    "github_cache/#{host}#{url}/#{suffix}"
  end

  # S3 I/O

  defp s3_req(config) do
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

  defp s3_url(config, key) do
    if config.plug do
      "/#{config.bucket}/#{key}"
    else
      "s3://#{config.bucket}/#{key}"
    end
  end

  defp get_object(config, key) do
    req = s3_req(config)
    url = s3_url(config, key)

    case Req.get(req, url: url, decode_body: false, retry: false) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      _ ->
        :miss
    end
  end

  defp put_object(config, key, body) do
    req = s3_req(config)
    url = s3_url(config, key)

    case Req.put(req, url: url, body: body) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status, body: resp_body}} ->
        Logger.error(
          "Failed to write GitHub S3 cache #{key}: status #{status}, body: #{inspect(resp_body)}"
        )

        :error

      {:error, reason} ->
        Logger.error("Failed to write GitHub S3 cache #{key}: #{inspect(reason)}")
        :error
    end
  end
end

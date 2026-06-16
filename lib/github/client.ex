defmodule GitHub.Client do
  @moduledoc """
  Req-based HTTP client for the GitHub REST API with optional S3 ETag caching.

  Resolves authentication (a token string, or a `GitHub.App` minting a JWT),
  performs conditional GETs against an S3 ETag cache when configured (304
  responses are free against rate limits), and normalizes non-success
  responses into `GitHub.Error` structs — classifying rate-limit and server
  errors so callers can match on `reason`.
  """

  require Logger

  alias GitHub.App
  alias GitHub.Error

  defmodule S3Config do
    @moduledoc false
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

  @default_server "https://api.github.com"
  @http_code_success 200..206
  @http_code_server_error 500..511

  @type auth :: nil | String.t() | App.t()
  @type opt ::
          {:auth, auth()}
          | {:params, keyword() | nil}
          | {:body, map() | nil}
          | {:server, String.t()}
          | {:plug, term()}
          | {:s3_cache, S3Config.t()}
  @type result :: {:ok, term()} | {:error, Error.t()}

  @client_opt_keys [:auth, :plug, :s3_cache, :server]

  @doc """
  Splits a resource function's options into client options, folding any
  remaining keys into `:params`.
  """
  @spec to_request_opts(keyword()) :: [opt]
  def to_request_opts(opts) do
    {client, params} = Keyword.split(opts, @client_opt_keys)
    Keyword.put(client, :params, params)
  end

  @doc "Issues a GET request. See `request/3`."
  @spec get(String.t(), [opt]) :: result()
  def get(url, opts \\ []), do: request(:get, url, opts)

  @doc "Issues a POST request. `:body` is JSON-encoded. See `request/3`."
  @spec post(String.t(), [opt]) :: result()
  def post(url, opts \\ []), do: request(:post, url, opts)

  @doc """
  Issues a request and returns `{:ok, decoded_body}` or `{:error, %GitHub.Error{}}`.
  """
  @spec request(atom(), String.t(), [opt]) :: result()
  def request(method, url, opts) do
    server = opts[:server] || @default_server
    s3_config = opts[:s3_cache] || s3_config()
    auth = opts[:auth]
    params = opts[:params]

    headers = auth_headers(auth) ++ default_headers()
    full_url = Path.join(server, url)

    {cached_entry, headers} =
      if s3_config && method == :get do
        maybe_add_etag(server, url, params, auth, s3_config, headers)
      else
        {nil, headers}
      end

    req_opts =
      [
        method: method,
        url: full_url,
        headers: headers,
        decode_body: false,
        redirect: true,
        retry: false
      ]
      |> maybe_add_body(opts[:body])
      |> maybe_add_params(params)
      |> maybe_add_plug(opts[:plug])

    case Req.request(Req.new(), req_opts) do
      {:ok, %Req.Response{} = response} ->
        process_response(method, url, server, params, auth, response, s3_config, cached_entry)

      {:error, reason} ->
        {:error,
         Error.new(
           message: "Error during HTTP request",
           source: reason,
           step: {__MODULE__, :request}
         )}
    end
  end

  @doc """
  Returns the S3 cache config from application environment, or nil if unset.
  """
  @spec s3_config() :: S3Config.t() | nil
  def s3_config do
    case Application.get_env(:tracker, :github_s3_cache) do
      nil -> nil
      opts -> struct!(S3Config, opts)
    end
  end

  defp default_headers do
    [
      {"accept", "application/vnd.github+json"},
      {"user-agent", "Tracker"}
    ]
  end

  defp auth_headers(nil), do: []
  defp auth_headers(token) when is_binary(token), do: [{"authorization", "Bearer #{token}"}]
  defp auth_headers(%App{} = app), do: [{"authorization", "Bearer #{App.jwt(app)}"}]

  defp maybe_add_body(opts, nil), do: opts
  defp maybe_add_body(opts, body), do: Keyword.put(opts, :json, body)

  defp maybe_add_params(opts, nil), do: opts
  defp maybe_add_params(opts, []), do: opts
  defp maybe_add_params(opts, params), do: Keyword.put(opts, :params, params)

  defp maybe_add_plug(opts, nil), do: opts
  defp maybe_add_plug(opts, plug), do: Keyword.put(opts, :plug, plug)

  # Response handling

  defp process_response(
         _method,
         _url,
         _server,
         _params,
         _auth,
         %Req.Response{status: 304},
         _s3,
         entry
       )
       when not is_nil(entry) do
    # 304 Not Modified — serve the cached body (free against rate limits).
    {:ok, decode_body(entry["response"])}
  end

  defp process_response(
         method,
         url,
         server,
         params,
         auth,
         %Req.Response{} = response,
         s3_config,
         _entry
       ) do
    %Req.Response{status: status, body: body} = response

    cond do
      status in @http_code_success ->
        if s3_config && method == :get do
          maybe_cache_response(server, url, params, auth, response, s3_config)
        end

        {:ok, decode_body(body)}

      true ->
        {:error, response_error(status, body, response)}
    end
  end

  defp response_error(status, body, response) do
    decoded = safe_decode(body)

    Error.new(
      code: status,
      reason: classify(status, decoded, response),
      message: error_message(status, decoded),
      source: body,
      step: {__MODULE__, :request}
    )
  end

  defp classify(status, _decoded, _response) when status in @http_code_server_error,
    do: :server_error

  defp classify(status, decoded, response) do
    cond do
      rate_limited?(status, decoded, response) -> :rate_limited
      status == 404 -> :not_found
      true -> :error
    end
  end

  defp rate_limited?(429, _decoded, _response), do: true

  defp rate_limited?(403, decoded, response) do
    rate_limit_message?(decoded) or remaining_exhausted?(response)
  end

  defp rate_limited?(_status, _decoded, _response), do: false

  defp rate_limit_message?(%{"message" => "API rate limit exceeded" <> _}), do: true
  defp rate_limit_message?(%{"message" => "You have exceeded a secondary" <> _}), do: true
  defp rate_limit_message?(_), do: false

  defp remaining_exhausted?(%Req.Response{} = response) do
    Req.Response.get_header(response, "x-ratelimit-remaining") == ["0"]
  end

  defp error_message(_status, %{"message" => message}) when is_binary(message), do: message
  defp error_message(404, _decoded), do: "Not Found"
  defp error_message(status, _decoded), do: "GitHub API error (#{status})"

  defp decode_body(""), do: nil
  defp decode_body(body) when is_binary(body), do: Jason.decode!(body)

  defp safe_decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      _ -> nil
    end
  end

  defp safe_decode(_), do: nil

  # S3 ETag cache

  defp maybe_add_etag(server, url, params, auth, s3_config, headers) do
    key = cache_key(server, url, params, auth)

    case get_object(s3_config, key) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"etag" => etag} = entry} ->
            {entry, [{"if-none-match", etag} | headers]}

          _ ->
            {nil, headers}
        end

      :miss ->
        {nil, headers}
    end
  end

  defp maybe_cache_response(server, url, params, auth, %Req.Response{} = response, s3_config) do
    case Req.Response.get_header(response, "etag") do
      [etag | _] ->
        key = cache_key(server, url, params, auth)

        entry =
          Jason.encode!(%{
            etag: etag,
            response: response.body,
            headers: Map.new(response.headers)
          })

        put_object(s3_config, key, entry)

      [] ->
        :ok
    end
  end

  @doc """
  Builds the S3 cache key for a request.

  Format: `github_cache/{host}{path}/{query_hash}_{auth_hash}` (the query
  hash is omitted when there are no params).
  """
  @spec cache_key(String.t(), String.t(), keyword() | nil, auth()) :: String.t()
  def cache_key(server, url, params, auth) do
    host = URI.parse(server).host

    query_hash =
      if params && params != [] do
        params
        |> Enum.sort_by(fn {k, _} -> to_string(k) end)
        |> URI.encode_query()
        |> short_hash()
      end

    auth_hash =
      case auth do
        token when is_binary(token) -> short_hash(token)
        _ -> "anon"
      end

    suffix = if query_hash, do: "#{query_hash}_#{auth_hash}", else: auth_hash

    "github_cache/#{host}#{url}/#{suffix}"
  end

  defp short_hash(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end

  # S3 I/O

  defp s3_req(config) do
    req = Req.new()

    if config.plug do
      Req.merge(req, plug: config.plug)
    else
      ReqS3.attach(req,
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
    case Req.get(s3_req(config), url: s3_url(config, key), decode_body: false, retry: false) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      _ -> :miss
    end
  end

  defp put_object(config, key, body) do
    case Req.put(s3_req(config), url: s3_url(config, key), body: body) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status, body: resp_body}} ->
        Logger.error(
          msg: "failed to write GitHub S3 cache",
          key: key,
          status: status,
          body: inspect(resp_body)
        )

        :error

      {:error, reason} ->
        Logger.error(msg: "failed to write GitHub S3 cache", key: key, reason: inspect(reason))
        :error
    end
  end
end

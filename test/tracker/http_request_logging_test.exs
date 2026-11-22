defmodule Tracker.HTTPRequestLoggingTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  @log_options [
    level: :warning,
    metadata: [:http_method, :http_destination],
    format: "$metadata$message\n"
  ]

  defmodule RedirectAdapter do
    def run(%Req.Request{} = request) do
      case request.url.host do
        "api.github.example" ->
          {request,
           Req.Response.new(
             status: 302,
             headers: [{"location", "https://download.example/artifact?signature=secret"}]
           )}

        "download.example" ->
          {request, %Req.HTTPError{protocol: :http1, reason: {:proxy, {:unexpected_status, 403}}}}
      end
    end
  end

  test "identifies a retried and exhausted request without logging secrets" do
    Req.Test.expect(__MODULE__, 2, &Req.Test.transport_error(&1, :closed))

    log =
      capture_log(@log_options, fn ->
        assert {:error, %Req.TransportError{reason: :closed}} =
                 Req.get("https://user:password@example.com:8443/path?token=secret#fragment",
                   plug: {Req.Test, __MODULE__},
                   retry_delay: 0,
                   max_retries: 1
                 )
      end)

    retry_line = Enum.find(String.split(log, "\n"), &String.contains?(&1, "retry:"))
    assert retry_line =~ "http_method=GET"
    assert retry_line =~ "http_destination=https://example.com:8443/path"
    assert length(Regex.scan(~r/HTTP request failed/, log)) == 1
    for secret <- ["password", "token", "secret", "fragment"], do: refute(log =~ secret)
  end

  test "does not log a terminal failure when the retry succeeds" do
    Req.Test.expect(__MODULE__, &Req.Test.transport_error(&1, :closed))
    Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 200, "ok"))

    log =
      capture_log(fn ->
        assert {:ok, %Req.Response{status: 200}} =
                 Req.get("https://example.com", plug: {Req.Test, __MODULE__}, retry_delay: 0)
      end)

    assert log =~ "retry:"
    refute log =~ "HTTP request failed"
  end

  test "logs a transport error once when retries are disabled" do
    Req.Test.expect(__MODULE__, &Req.Test.transport_error(&1, :closed))

    log =
      capture_log(@log_options, fn ->
        assert {:error, %Req.TransportError{reason: :closed}} =
                 Req.get("https://example.com", plug: {Req.Test, __MODULE__}, retry: false)
      end)

    assert length(Regex.scan(~r/HTTP request failed/, log)) == 1
    assert log =~ "http_destination=https://example.com:443/"
    refute log =~ "retry:"
  end

  test "logs the effective destination when a redirect's CONNECT is rejected" do
    log =
      capture_log(@log_options, fn ->
        assert {:error, %Req.HTTPError{}} =
                 Req.get("https://api.github.example/archive",
                   adapter: RedirectAdapter,
                   retry: false
                 )
      end)

    assert length(Regex.scan(~r/proxy CONNECT rejected/, log)) == 1
    assert log =~ "proxy_status: 403"
    assert log =~ "https://download.example:443/artifact"
    refute log =~ "signature"
    refute log =~ "api.github.example"
    refute log =~ "retry:"
  end
end

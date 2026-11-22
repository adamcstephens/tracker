defmodule Tracker.HTTPRequestLogging do
  @moduledoc """
  Adds the effective request destination to Req retry and terminal network error logs.
  Destinations omit userinfo, query strings, and fragments.
  """

  require Logger

  def attach(%Req.Request{} = request) do
    request = %{
      request
      | response_steps: Keyword.replace!(request.response_steps, :retry, &retry/1),
        error_steps: Keyword.replace!(request.error_steps, :retry, &retry/1)
    }

    Req.Request.append_error_steps(request, log_network_failure: &log_network_failure/1)
  end

  defp retry({%Req.Request{} = request, _result} = step) do
    previous = Logger.metadata()
    Logger.metadata(request_metadata(request))

    try do
      Req.Steps.retry(step)
    after
      Logger.reset_metadata(previous)
    end
  end

  defp log_network_failure(
         {%Req.Request{} = request,
          %Req.HTTPError{reason: {:proxy, {:unexpected_status, status}}}} = step
       ) do
    Logger.warning(
      [msg: "proxy CONNECT rejected", proxy_status: status],
      request_metadata(request)
    )

    step
  end

  defp log_network_failure({%Req.Request{} = request, %error{} = exception} = step)
       when error in [Req.TransportError, Req.HTTPError] do
    Logger.warning(
      [msg: "HTTP request failed", reason: Exception.message(exception)],
      request_metadata(request)
    )

    step
  end

  defp log_network_failure(step), do: step

  defp request_metadata(%Req.Request{} = request) do
    uri = request.url
    host = if uri.host && String.contains?(uri.host, ":"), do: "[#{uri.host}]", else: uri.host
    port = if uri.port, do: ":#{uri.port}", else: ""

    [
      http_method: request.method |> Atom.to_string() |> String.upcase(),
      http_destination: "#{uri.scheme}://#{host}#{port}#{uri.path || "/"}"
    ]
  end
end

defmodule Tracker.GitHub.Telemetry do
  @moduledoc false

  @resources [
    "core",
    "search",
    "code_search",
    "graphql",
    "integration_manifest",
    "source_import",
    "code_scanning_upload",
    "actions_runner_registration",
    "scim",
    "dependency_snapshots",
    "audit_log",
    "audit_log_streaming"
  ]

  @headers [
    {:limit, "x-ratelimit-limit"},
    {:remaining, "x-ratelimit-remaining"},
    {:reset_timestamp_seconds, "x-ratelimit-reset"}
  ]

  def observe_rest(%Req.Response{} = response) do
    emit_quota(header_measurements(response), resource(response))
  end

  def rate_limited(%Req.Response{} = response) do
    emit_rate_limited(resource(response))
  end

  def observe_graphql(%Req.Response{} = response) do
    quota = graphql_quota(response.body)
    measurements = header_measurements(response)

    measurements =
      case quota do
        %{} ->
          measurements
          |> put_integer(:limit, quota["limit"])
          |> put_integer(:remaining, quota["remaining"])
          |> put_reset(quota["resetAt"])

        _ ->
          measurements
      end

    emit_quota(measurements, "graphql")

    case quota do
      %{"cost" => cost} when is_integer(cost) and cost >= 0 ->
        :telemetry.execute([:tracker, :github, :graphql, :cost], %{cost: cost}, %{
          resource: "graphql"
        })

      _ ->
        :ok
    end

    if response.status in [403, 429] or graphql_rate_limited?(response.body) do
      emit_rate_limited("graphql")
    end

    :ok
  end

  defp resource(%Req.Response{} = response) do
    case Req.Response.get_header(response, "x-ratelimit-resource") do
      [resource | _] when resource in @resources -> resource
      _ -> "core"
    end
  end

  defp header_measurements(%Req.Response{} = response) do
    Enum.reduce(@headers, %{}, fn {measurement, header}, measurements ->
      case Req.Response.get_header(response, header) do
        [value | _] ->
          case Integer.parse(value) do
            {number, ""} -> put_integer(measurements, measurement, number)
            _ -> measurements
          end

        _ ->
          measurements
      end
    end)
  end

  defp put_integer(measurements, key, value) when is_integer(value) and value >= 0,
    do: Map.put(measurements, key, value)

  defp put_integer(measurements, _key, _value), do: measurements

  defp put_reset(measurements, reset_at) when is_binary(reset_at) do
    case DateTime.from_iso8601(reset_at) do
      {:ok, datetime, _} ->
        put_integer(measurements, :reset_timestamp_seconds, DateTime.to_unix(datetime))

      _ ->
        measurements
    end
  end

  defp put_reset(measurements, _reset_at), do: measurements

  defp graphql_quota(%{"data" => %{"rateLimit" => %{} = quota}}), do: quota
  defp graphql_quota(_body), do: nil

  defp graphql_rate_limited?(%{"errors" => errors}) when is_list(errors) do
    Enum.any?(errors, &match?(%{"type" => "RATE_LIMITED"}, &1))
  end

  defp graphql_rate_limited?(_body), do: false

  defp emit_quota(measurements, resource) when map_size(measurements) > 0 do
    :telemetry.execute(
      [:tracker, :github, :rate_limit],
      Map.put(measurements, :observed_timestamp_seconds, System.os_time(:second)),
      %{resource: resource}
    )
  end

  defp emit_quota(_measurements, _resource), do: :ok

  defp emit_rate_limited(resource) do
    :telemetry.execute([:tracker, :github, :rate_limited], %{count: 1}, %{resource: resource})
  end
end

defmodule TrackerWeb.MetricsTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  setup do
    previous = Application.get_env(:tracker, :metrics_token)
    Application.put_env(:tracker, :metrics_token, "scrape-test-secret")

    on_exit(fn ->
      if previous do
        Application.put_env(:tracker, :metrics_token, previous)
      else
        Application.delete_env(:tracker, :metrics_token)
      end
    end)
  end

  test "rejects missing, incorrect and duplicate credentials without a login redirect" do
    for headers <- [
          [],
          [{"authorization", "Bearer wrong"}],
          [{"authorization", "Basic scrape-test-secret"}]
        ] do
      response = request("GET", headers)
      assert response.status == 401
      assert get_resp_header(response, "location") == []
      assert get_resp_header(response, "set-cookie") == []
    end

    response =
      conn(:get, "/metrics")
      |> Map.put(:req_headers, [
        {"authorization", "Bearer scrape-test-secret"},
        {"authorization", "Bearer wrong"}
      ])
      |> TrackerWeb.Endpoint.call(TrackerWeb.Endpoint.init([]))

    assert response.status == 401
  end

  test "serves authenticated Prometheus exposition outside browser sessions" do
    response = request("GET", [{"authorization", "Bearer scrape-test-secret"}])

    assert response.status == 200
    assert get_resp_header(response, "content-type") == ["text/plain; charset=utf-8"]
    assert get_resp_header(response, "set-cookie") == []
  end

  test "does not expose metrics when no token is configured" do
    Application.delete_env(:tracker, :metrics_token)
    assert request("GET", [{"authorization", "Bearer scrape-test-secret"}]).status == 404

    Application.put_env(:tracker, :metrics_token, "")
    assert request("GET", [{"authorization", "Bearer "}]).status == 404
  end

  test "rejects writes even with valid credentials" do
    assert request("POST", [{"authorization", "Bearer scrape-test-secret"}]).status == 405
  end

  defp request(method, headers) do
    Enum.reduce(headers, conn(method, "/metrics"), fn {name, value}, conn ->
      put_req_header(conn, name, value)
    end)
    |> TrackerWeb.Endpoint.call(TrackerWeb.Endpoint.init([]))
  end
end

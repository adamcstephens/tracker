defmodule Tracker.RuntimeConfigTest do
  use ExUnit.Case, async: false

  test "leaves Req defaults unchanged without https_proxy" do
    refute Keyword.has_key?(runtime_config(nil), :req)
  end

  test "configures an HTTP proxy with its default port" do
    assert proxy_options("http://proxy.example") == [proxy: {:http, "proxy.example", 80, []}]
  end

  test "configures an HTTPS proxy with basic authentication and its default port" do
    assert proxy_options("https://myuser:mypass@myproxy.domain") == [
             proxy: {:https, "myproxy.domain", 443, []},
             proxy_headers: [
               {"proxy-authorization", "Basic " <> Base.encode64("myuser:mypass")}
             ]
           ]
  end

  test "preserves explicit ports and decodes credentials without treating plus as space" do
    assert proxy_options("http://my%40user:p%3Ass+word@proxy.example:3128") == [
             proxy: {:http, "proxy.example", 3128, []},
             proxy_headers: [
               {"proxy-authorization", "Basic " <> Base.encode64("my@user:p:ss+word")}
             ]
           ]
  end

  test "configures no_proxy bypass for Req requests" do
    defaults =
      runtime_config("http://proxy.example:3128", "localhost")
      |> Keyword.fetch!(:req)
      |> Keyword.fetch!(:default_options)

    request =
      defaults
      |> Req.new()
      |> Req.merge(url: "http://localhost:4000")
      |> Req.Request.prepare()

    refute Keyword.has_key?(request.options.connect_options, :proxy)
  end

  test "defaults the production HTTP bind address to all IPv6 interfaces" do
    assert production_http_ip(nil) == {0, 0, 0, 0, 0, 0, 0, 0}
  end

  test "configures an IPv4 production HTTP bind address" do
    assert production_http_ip("127.0.0.1") == {127, 0, 0, 1}
  end

  test "configures an IPv6 production HTTP bind address" do
    assert production_http_ip("::1") == {0, 0, 0, 0, 0, 0, 0, 1}
  end

  test "rejects an invalid production HTTP bind address" do
    assert_raise MatchError, fn -> production_http_ip("invalid-address") end
  end

  defp production_http_ip(ip) do
    environment = [
      {"PHX_IP", ip},
      {"TRACKER_GITHUB_CLIENT_ID", "client"},
      {"TRACKER_GITHUB_CLIENT_SECRET_FILE", __ENV__.file},
      {"TRACKER_GITHUB_APP_ID", "1"},
      {"TRACKER_GITHUB_APP_PRIVATE_KEY_FILE", __ENV__.file},
      {"TRACKER_GITHUB_INSTALLATION_ID", "1"},
      {"TRACKER_GITHUB_REDIRECT_URI", "https://example.com"},
      {"DATABASE_URL", "ecto://localhost/tracker"},
      {"SECRET_KEY_BASE", String.duplicate("a", 64)},
      {"TOKEN_SIGNING_SECRET", "secret"}
    ]

    previous = Enum.map(environment, fn {name, _value} -> {name, System.get_env(name)} end)

    try do
      Enum.each(environment, fn {name, value} -> set_env(name, value) end)

      Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
      |> Keyword.fetch!(:tracker)
      |> Keyword.fetch!(TrackerWeb.Endpoint)
      |> Keyword.fetch!(:http)
      |> Keyword.fetch!(:ip)
    after
      Enum.each(previous, fn {name, value} -> set_env(name, value) end)
    end
  end

  defp proxy_options(url) do
    runtime_config(url)
    |> Keyword.get(:req, [])
    |> Keyword.fetch!(:default_options)
    |> Keyword.fetch!(:connect_options)
  end

  defp runtime_config(url, no_proxy \\ nil) do
    previous =
      Enum.map(["https_proxy", "no_proxy"], fn name -> {name, System.get_env(name)} end)

    try do
      set_env("https_proxy", url)
      set_env("no_proxy", no_proxy)
      Config.Reader.read!("config/runtime.exs", env: :test, target: :host)
    after
      Enum.each(previous, fn {name, value} -> set_env(name, value) end)
    end
  end

  defp set_env(name, nil), do: System.delete_env(name)
  defp set_env(name, value), do: System.put_env(name, value)
end

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

  defp proxy_options(url) do
    runtime_config(url)
    |> Keyword.get(:req, [])
    |> Keyword.fetch!(:default_options)
    |> Keyword.fetch!(:connect_options)
  end

  defp runtime_config(url) do
    previous = System.get_env("https_proxy")

    try do
      set_proxy(url)
      Config.Reader.read!("config/runtime.exs", env: :test, target: :host)
    after
      set_proxy(previous)
    end
  end

  defp set_proxy(nil), do: System.delete_env("https_proxy")
  defp set_proxy(url), do: System.put_env("https_proxy", url)
end

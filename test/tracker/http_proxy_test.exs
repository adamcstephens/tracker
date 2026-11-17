defmodule Tracker.HTTPProxyTest do
  use ExUnit.Case, async: true

  @connect_options [
    proxy: {:http, "proxy.example", 3128, []},
    proxy_headers: [{"proxy-authorization", "Basic credentials"}],
    timeout: 1234
  ]

  defmodule Endpoint do
    def init(options), do: options

    def call(conn, options) do
      send(options[:owner], {
        :request,
        options[:name],
        Plug.Conn.get_req_header(conn, "proxy-authorization")
      })

      case conn.request_path do
        "/redirect" ->
          conn
          |> Plug.Conn.put_resp_header("location", options[:target])
          |> Plug.Conn.send_resp(302, "")

        _ ->
          Plug.Conn.send_resp(conn, 200, "ok")
      end
    end
  end

  test "matches hosts, domains, IP literals, ports and wildcard without overmatching" do
    for {no_proxy, url, bypass?} <- [
          {"localhost", "http://localhost/", true},
          {" localhost , 127.0.0.1, ::1 ", "https://127.0.0.1/", true},
          {"::1", "https://[::1]/", true},
          {"[::1]:443", "https://[::1]/", true},
          {"[::1]:80", "https://[::1]/", false},
          {"2001:db8::1", "https://[2001:db8:0:0:0:0:0:1]/", true},
          {"EXAMPLE.com", "https://api.example.COM/", true},
          {".example.com", "https://example.com/", true},
          {".example.com", "https://nested.api.example.com/", true},
          {"example.com", "https://badexample.com/", false},
          {"example.com", "https://example.com.evil/", false},
          {"example.com:443", "https://example.com/", true},
          {"example.com:443", "https://example.com:444/", false},
          {"127.0.0.1", "http://other.127.0.0.1/", false},
          {"*", "https://anything.example/", true},
          {", ,", "https://example.com/", false},
          {"", "https://example.com/", false}
        ] do
      request = url |> request(no_proxy) |> Req.Request.prepare()
      expected = if bypass?, do: [timeout: 1234], else: @connect_options
      assert request.options.connect_options == expected, "#{no_proxy} against #{url}"
    end
  end

  test "uses the effective URL after base_url is applied" do
    prepared =
      request("/path", "localhost")
      |> Req.merge(base_url: "http://localhost:4000")
      |> Req.Request.prepare()

    assert prepared.options.connect_options == [timeout: 1234]
  end

  test "redirects from direct to proxied and removes and restores proxy authentication" do
    proxy = start_endpoint(:proxy, "")
    direct = start_endpoint(:direct, "http://proxied.invalid/final")

    req = network_request("http://127.0.0.1:#{direct}/redirect", proxy)
    assert Req.get!(req).status == 200
    assert_received {:request, :direct, []}
    assert_received {:request, :proxy, ["Basic credentials"]}
  end

  test "redirects from proxied to direct without leaking proxy authentication" do
    direct = start_endpoint(:direct, "")
    proxy = start_endpoint(:proxy, "http://127.0.0.1:#{direct}/final")

    req = network_request("http://proxied.invalid/redirect", proxy)
    assert Req.get!(req).status == 200
    assert_received {:request, :proxy, ["Basic credentials"]}
    assert_received {:request, :direct, []}
  end

  defp request(url, no_proxy) do
    Req.new(
      url: url,
      plugins: [Tracker.HTTPProxy],
      no_proxy: Tracker.HTTPProxy.parse_no_proxy(no_proxy),
      connect_options: @connect_options
    )
  end

  defp network_request(url, proxy_port) do
    request(url, "127.0.0.1")
    |> Req.merge(
      retry: false,
      connect_options: Keyword.put(@connect_options, :proxy, {:http, "127.0.0.1", proxy_port, []})
    )
  end

  defp start_endpoint(name, target) do
    server =
      start_supervised!(
        {Bandit,
         plug: {Endpoint, owner: self(), name: name, target: target},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false},
        id: name
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    port
  end
end

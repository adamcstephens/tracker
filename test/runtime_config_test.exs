defmodule Tracker.RuntimeConfigTest do
  use ExUnit.Case, async: false

  test "development disables GitHub without requiring credentials" do
    previous = System.get_env("TRACKER_GITHUB_ENABLED")

    try do
      System.delete_env("TRACKER_GITHUB_ENABLED")
      config = Config.Reader.read!("config/runtime.exs", env: :dev, target: :host)
      assert config[:tracker][:github_enabled] == false
      refute config[:tracker][:github]
    after
      set_env("TRACKER_GITHUB_ENABLED", previous)
    end
  end

  test "development can opt into GitHub with credentials" do
    config = production_config([{"TRACKER_GITHUB_ENABLED", "true"}], :dev)
    assert config[:tracker][:github_enabled]
    assert config[:tracker][:github][:client_id] == "client"
  end

  test "production keeps GitHub enabled by default" do
    config = production_config([])
    assert config[:tracker][:github_enabled]
    assert config[:tracker][:github][:client_id] == "client"
  end

  test "production can disable GitHub without credentials" do
    config =
      production_config([
        {"TRACKER_GITHUB_ENABLED", "false"},
        {"TRACKER_GITHUB_CLIENT_ID", nil},
        {"TRACKER_GITHUB_APP_PRIVATE_KEY_FILE", "/missing"}
      ])

    refute config[:tracker][:github_enabled]
    refute config[:tracker][:github]
  end

  test "invalid GitHub enablement fails rather than silently disabling production" do
    assert_raise RuntimeError, ~r/TRACKER_GITHUB_ENABLED must be true or false/, fn ->
      production_config([{"TRACKER_GITHUB_ENABLED", "tru"}])
    end
  end

  test "configures Req logging without https_proxy" do
    assert runtime_config(nil)[:req][:default_options] == [plugins: [Tracker.HTTPRequestLogging]]
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

    assert defaults[:plugins] == [Tracker.HTTPRequestLogging, Tracker.HTTPProxy]

    request =
      defaults
      |> Req.new()
      |> Req.merge(url: "http://localhost:4000")
      |> Req.Request.prepare()

    refute Keyword.has_key?(request.options.connect_options, :proxy)
  end

  test "routes both GitHub OAuth origins through the authenticated proxy" do
    config = runtime_config("http://user:pass@proxy.example:3128")
    options = config[:req][:default_options][:connect_options]

    assert config[:ash_authentication][:http_adapter] ==
             {Assent.HTTPAdapter.Finch, supervisor: Tracker.Finch}

    assert config[:tracker][Tracker.Finch][:pools] == %{
             "https://github.com" => [conn_opts: options],
             "https://api.github.com" => [conn_opts: options]
           }
  end

  test "Assent opens a proxy tunnel for the token exchange and profile request" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, port} = :inet.port(listener)
    config = runtime_config("http://127.0.0.1:#{port}")
    {adapter, options} = config[:ash_authentication][:http_adapter]
    start_supervised!({Finch, [name: __MODULE__] ++ config[:tracker][Tracker.Finch]})
    options = Keyword.replace!(options, :supervisor, __MODULE__)

    for {method, host, path} <- [
          {:post, "github.com", "/login/oauth/access_token"},
          {:get, "api.github.com", "/user"}
        ] do
      request =
        Task.async(fn -> adapter.request(method, "https://#{host}#{path}", nil, [], options) end)

      {:ok, socket} = :gen_tcp.accept(listener, 2_000)
      :ok = :inet.setopts(socket, packet: :line)
      assert {:ok, "CONNECT #{host}:443 HTTP/1.1\r\n"} == :gen_tcp.recv(socket, 0, 2_000)
      :ok = :gen_tcp.send(socket, "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")

      assert {:error, %Finch.HTTPError{reason: {:proxy, {:unexpected_status, 403}}}} =
               Task.await(request)

      :ok = :gen_tcp.close(socket)
    end
  end

  test "honors no_proxy independently for each OAuth origin" do
    config = runtime_config("http://proxy.example:3128", "api.github.com:443")

    assert config[:tracker][Tracker.Finch][:pools] == %{
             "https://github.com" => [conn_opts: [proxy: {:http, "proxy.example", 3128, []}]],
             "https://api.github.com" => [conn_opts: []]
           }
  end

  test "keeps the default OAuth adapter without https_proxy" do
    config = runtime_config(nil)
    refute config[:ash_authentication][:http_adapter]
    refute config[:tracker][Tracker.Finch]
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

  @tag :tmp_dir
  test "reads production secrets from files before checking the environment", %{tmp_dir: dir} do
    secrets = [
      {"DATABASE_URL", "ecto://localhost/from_file"},
      {"SECRET_KEY_BASE", String.duplicate("b", 64)},
      {"TOKEN_SIGNING_SECRET", "signing"},
      {"TRACKER_DISCORD_TOKEN", "discord"},
      {"TRACKER_METRICS_TOKEN", "metrics"},
      {"TRACKER_S3_ACCESS_KEY", "access"},
      {"TRACKER_S3_SECRET_KEY", "secret"}
    ]

    files =
      Enum.flat_map(secrets, fn {name, value} ->
        path = Path.join(dir, name)
        File.write!(path, value <> "\n")
        [{name <> "_FILE", path}, {name, "ignored"}]
      end)

    config =
      production_config(
        files ++
          [
            {"TRACKER_S3_BUCKET", "bucket"},
            {"TRACKER_S3_ENDPOINT", "https://s3.example.com"},
            {"TRACKER_S3_REGION", "region"}
          ]
      )

    tracker = Keyword.fetch!(config, :tracker)
    assert tracker[Tracker.Repo][:url] == "ecto://localhost/from_file"
    assert tracker[TrackerWeb.Endpoint][:secret_key_base] == String.duplicate("b", 64)
    assert tracker[:token_signing_secret] == "signing"
    assert tracker[:metrics_token] == "metrics"
    assert config[:nostrum][:token] == "discord"
    assert tracker[:s3_cache][:access_key_id] == "access"
    assert tracker[:s3_cache][:secret_access_key] == "secret"
  end

  @tag :tmp_dir
  test "fails when a configured secret file is missing despite an environment value", %{
    tmp_dir: dir
  } do
    assert_raise File.Error, fn ->
      production_config([{"TOKEN_SIGNING_SECRET_FILE", Path.join(dir, "missing")}])
    end
  end

  defp production_http_ip(ip) do
    production_config([{"PHX_IP", ip}])
    |> Keyword.fetch!(:tracker)
    |> Keyword.fetch!(TrackerWeb.Endpoint)
    |> Keyword.fetch!(:http)
    |> Keyword.fetch!(:ip)
  end

  defp production_config(overrides, env \\ :prod) do
    environment = [
      {"TRACKER_GITHUB_ENABLED", nil},
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

    environment = Enum.uniq_by(overrides ++ environment, &elem(&1, 0))

    previous = Enum.map(environment, fn {name, _value} -> {name, System.get_env(name)} end)

    try do
      Enum.each(environment, fn {name, value} -> set_env(name, value) end)

      Config.Reader.read!("config/runtime.exs", env: env, target: :host)
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

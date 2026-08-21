defmodule TrackerWeb.Browser.OptionTreeTest do
  use TrackerWeb.PlaywrightCase

  alias Tracker.Nixpkgs.Channel
  alias Tracker.Nixpkgs.ChannelRevision

  @options %{
    "services.nginx.enable" => %{
      "declarations" => ["nixos/modules/services/web-servers/nginx/default.nix"],
      "description" => "Enable Nginx.",
      "loc" => ["services", "nginx", "enable"],
      "readOnly" => false,
      "type" => "boolean"
    },
    "services.nginx.virtualHosts.example.serverName" => %{
      "declarations" => ["nixos/modules/services/web-servers/nginx/vhost-options.nix"],
      "description" => "Server name for the vhost.",
      "loc" => ["services", "nginx", "virtualHosts", "example", "serverName"],
      "readOnly" => false,
      "type" => "string"
    }
  }

  setup do
    channel =
      Channel.create!(%{
        name: "nixos-opttree",
        display_name: "NixOS Unstable",
        status: :active,
        is_stable: true
      })

    cr =
      ChannelRevision.create!(%{
        channel_id: channel.id,
        revision: "treeabc1234567",
        released_at: ~U[2026-03-15 10:00:00Z]
      })

    ChannelRevision.record_result!(cr, %{result: :success})
    cr = ChannelRevision.record_options_result!(cr, %{options_result: :success})

    Tracker.Fixtures.load_options(@options, cr)

    path = Path.join(System.tmp_dir!(), "dev-login-#{System.unique_integer([:positive])}.json")
    Application.put_env(:tracker, :dev_login_file, path)
    on_exit(fn -> File.rm(path) end)

    :ok
  end

  defp sign_in(conn) do
    user = register_user!()
    visit(conn, "/dev/login/#{Tracker.DevLogin.issue!(user.github_username)}")
  end

  defp read(conn, expression) do
    parent = self()
    evaluate(conn, expression, &send(parent, {:read, &1}))

    receive do
      {:read, value} -> value
    after
      0 -> flunk("evaluate/3 returned no value for #{expression}")
    end
  end

  defp path(conn), do: read(conn, "window.location.pathname")

  for key <- ~w(u h) do
    @key key

    test "#{key} climbs to the parent prefix", %{conn: conn} do
      conn = visit(conn, ~p"/options/services.nginx.virtualHosts")

      press(conn, "body", @key)

      assert path(conn) == "/options/services.nginx"
    end
  end

  test "u climbs from the shallowest prefix out to the options root", %{conn: conn} do
    conn = visit(conn, ~p"/options/services")

    press(conn, "body", "u")

    assert path(conn) == "/options"
  end

  test "u keeps the lens channel", %{conn: conn} do
    conn = visit(conn, ~p"/options/services.nginx?channel=nixos-opttree")

    press(conn, "body", "u")

    assert path(conn) == "/options/services"
    assert read(conn, "window.location.search") == "?channel=nixos-opttree"
  end

  test "u navigates live rather than reloading the page", %{conn: conn} do
    conn =
      conn
      |> sign_in()
      |> visit(~p"/options/services.nginx.virtualHosts")
      |> evaluate("window.__survived = true")

    press(conn, "body", "u")
    assert_path(conn, "/options/services.nginx")

    assert read(conn, "window.__survived") == true
  end

  test "u is inert at the options root", %{conn: conn} do
    conn = visit(conn, ~p"/options")

    press(conn, "body", "u")

    assert path(conn) == "/options"
  end

  test "u is inert while typing in search", %{conn: conn} do
    conn = visit(conn, ~p"/options/services.nginx")

    press(conn, "#page-search-input", "u")

    assert path(conn) == "/options/services.nginx"
  end

  test "u is inert while the shortcuts dialog is open", %{conn: conn} do
    conn = visit(conn, ~p"/options/services.nginx")

    evaluate(conn, ~s|document.getElementById("shortcuts").showModal()|)
    press(conn, "body", "u")

    assert path(conn) == "/options/services.nginx"
  end
end

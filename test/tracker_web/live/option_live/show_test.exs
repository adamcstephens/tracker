defmodule TrackerWeb.OptionLive.ShowTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Tracker.Fixtures
  alias Tracker.Nixpkgs.Channel

  @nginx_options %{
    "services.nginx.enable" => %{
      "declarations" => ["nixos/modules/services/web-servers/nginx/default.nix"],
      "description" => "Enable Nginx.",
      "loc" => ["services", "nginx", "enable"],
      "readOnly" => false,
      "type" => "boolean",
      "default" => %{"_type" => "literalExpression", "text" => "false"}
    },
    "services.nginx.user" => %{
      "declarations" => ["nixos/modules/services/web-servers/nginx/default.nix"],
      "description" => "User to run Nginx as.",
      "loc" => ["services", "nginx", "user"],
      "readOnly" => false,
      "type" => "string"
    },
    "services.nginx.virtualHosts.example.serverName" => %{
      "declarations" => ["nixos/modules/services/web-servers/nginx/vhost-options.nix"],
      "description" => "Server name for the vhost.",
      "loc" => ["services", "nginx", "virtualHosts", "example", "serverName"],
      "readOnly" => false,
      "type" => "string"
    },
    "services.nginx.virtualHosts.example.locations.\"/\".proxyPass" => %{
      "declarations" => ["nixos/modules/services/web-servers/nginx/location-options.nix"],
      "description" => "Proxy pass URL.",
      "loc" => [
        "services",
        "nginx",
        "virtualHosts",
        "example",
        "locations",
        "/",
        "proxyPass"
      ],
      "readOnly" => false,
      "type" => "string"
    }
  }

  setup do
    channel =
      Channel.create!(%{
        name: "nixos-unstable",
        display_name: "NixOS Unstable",
        branch: "nixos-unstable",
        status: :active,
        is_stable: true
      })

    cr =
      Tracker.Nixpkgs.ChannelRevision.create!(%{
        channel_id: channel.id,
        revision: "showabc1234567",
        released_at: ~U[2026-03-15 10:00:00Z]
      })

    Tracker.Nixpkgs.ChannelRevision.record_result!(cr, %{result: :success})
    cr = Tracker.Nixpkgs.ChannelRevision.record_options_result!(cr, %{options_result: :success})

    Fixtures.load_options(@nginx_options, cr)

    %{channel: channel, channel_revision: cr}
  end

  test "renders the prefix as the page heading", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/options/services.nginx")

    assert html =~ "services.nginx"
  end

  test "shows leaf options at the immediate child depth", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/options/services.nginx")

    assert html =~ "services.nginx.enable"
    assert html =~ "services.nginx.user"
    # Deeper options must not be rendered as leaves at this depth
    refute html =~ "services.nginx.virtualHosts.example.serverName"
  end

  test "shows sub-groups for deeper descendants", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/options/services.nginx")

    assert html =~ "Sub-groups"
    assert html =~ "services.nginx.virtualHosts"
  end

  test "lists files defined-in for the prefix", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/options/services.nginx")

    assert html =~ "Defined in"
    assert html =~ "nixos/modules/services/web-servers/nginx/default.nix"
    assert html =~ "nixos/modules/services/web-servers/nginx/vhost-options.nix"
    assert html =~ "nixos/modules/services/web-servers/nginx/location-options.nix"
  end

  test "leaf options are linked to their files", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/options/services.nginx")

    # github link in the leaf option detail body
    assert html =~
             "https://github.com/NixOS/nixpkgs/blob/showabc1234567/" <>
               "nixos/modules/services/web-servers/nginx/default.nix"
  end

  test "drilling into a sub-group works", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/options/services.nginx.virtualHosts")

    # At this prefix, the sub-group is the per-vhost example name
    assert html =~ "services.nginx.virtualHosts.example"
  end

  test "leaf-only prefix renders the option detail card", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/options/services.nginx.enable")

    assert html =~ "Enable Nginx."
    assert html =~ "boolean"
  end

  test "shows fallback when channel has no options data", %{conn: conn} do
    nixpkgs_channel =
      Channel.create!(%{
        name: "nixpkgs-unstable",
        display_name: "Nixpkgs Unstable",
        branch: "nixpkgs-unstable",
        status: :active,
        is_stable: false
      })

    Tracker.Nixpkgs.ChannelRevision.create!(%{
      channel_id: nixpkgs_channel.id,
      revision: "nooptsabc12345",
      released_at: ~U[2026-03-01 10:00:00Z]
    })

    {:ok, _view, html} = live(conn, "/options/services.nginx?channel=nixpkgs-unstable")

    assert html =~ "doesn&#39;t have options"
  end

  test "lens change patches the URL and reloads", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/options/services.nginx")

    send(view.pid, {:set_lens, "nixos-unstable", ""})
    # Should still render the prefix
    html = render(view)
    assert html =~ "services.nginx"
  end
end

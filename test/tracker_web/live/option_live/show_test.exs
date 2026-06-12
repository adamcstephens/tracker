defmodule TrackerWeb.OptionLive.ShowTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  require Ash.Query

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
    "services.nginx.virtualHosts" => %{
      "declarations" => ["nixos/modules/services/web-servers/nginx/default.nix"],
      "description" => "Declarative vhost config.",
      "loc" => ["services", "nginx", "virtualHosts"],
      "readOnly" => false,
      "type" => "attribute set of (submodule)"
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

  test "renders the prefix as a breadcrumb path bar heading", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/options/services.nginx")

    # The h1 reads as the whole attribute path for screen readers
    assert html =~ ~s(aria-label="services.nginx")
    # Every segment but the last links to its cumulative prefix
    assert html =~ ~s(href="/options/services")
    # The last segment is the current page, not a link
    assert html =~ ~s(aria-current="page")
  end

  test "path bar has a copy button that copies the attribute path", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/options/services.nginx")

    assert html =~ ~s(data-copy="services.nginx")
    # Inline handler so copy works on dead renders (no app.js for anonymous)
    assert html =~ "navigator.clipboard.writeText"
  end

  test "meta strip shows a channel chip linking to the channel revision", %{
    conn: conn,
    channel_revision: cr
  } do
    {:ok, _view, html} = live(conn, ~p"/options/services.nginx")

    assert html =~ ~s(href="/channels/nixos-unstable/revisions/#{cr.revision}")
    assert html =~ "@#{String.slice(cr.revision, 0, 7)}"
  end

  test "shows leaf options at the immediate child depth", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/options/services.nginx")

    assert html =~ "services.nginx.enable"
    assert html =~ "services.nginx.user"
    # Deeper options must not be rendered as leaves at this depth
    refute html =~ "services.nginx.virtualHosts.example.serverName"
  end

  test "shows deeper descendants as Children cards", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/options/services.nginx")

    assert html =~ "Children"
    refute html =~ "Sub-groups"
    assert html =~ "services.nginx.virtualHosts"
    # The child card links to the sub-group prefix
    assert html =~ ~s(href="/options/services.nginx.virtualHosts")
  end

  test "leaf option rows carry a share link instead of the # anchor", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/options/services.nginx")

    # A real link to the option's own page, hooked for copy-to-clipboard
    assert html =~ ~s(href="/options/services.nginx.enable")
    assert html =~ "opt-share"
    refute html =~ "option-anchor"
  end

  test "pure group prefix lists a top-level Defined-in section", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/options/services")

    assert html =~ "Defined in"
    assert html =~ "nixos/modules/services/web-servers/nginx/vhost-options.nix"
    assert html =~ "nixos/modules/services/web-servers/nginx/location-options.nix"
  end

  test "an option matching the prefix renders as italic self", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/options/services.nginx.virtualHosts")

    assert html =~ ~s(<em class="tail">self</em>)
  end

  test "prefix with leaf options omits the top-level Defined-in section", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/options/services.nginx")

    # Per-option Defined-in stays inside the accordion (default.nix), but the
    # deeper descendants' files are not listed at the top level.
    assert html =~ "nixos/modules/services/web-servers/nginx/default.nix"
    refute html =~ "nixos/modules/services/web-servers/nginx/location-options.nix"
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
    # The full type is repeated inside the detail body (summary tag truncates)
    assert html =~ ">Type<"
  end

  test "a single option is expanded by default", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/options/services.nginx.enable")

    assert html =~ ~r/<details[^>]* open/
  end

  test "multiple options are collapsed by default", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/options/services.nginx")

    refute html =~ ~r/<details[^>]* open/
  end

  test "shows fallback when channel has no options data", %{conn: conn} do
    nixpkgs_channel =
      Channel.create!(%{
        name: "nixpkgs-unstable",
        display_name: "Nixpkgs Unstable",
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

  test "lists recent PRs whose change_files intersect the prefix's file set", %{conn: conn} do
    %{id: change_id} =
      Tracker.Nixpkgs.Change
      |> Ash.Changeset.for_create(:bulk_upsert, %{
        number: 7777,
        title: "nginx: bump to 1.27",
        state: :merged,
        url: "https://github.com/NixOS/nixpkgs/pull/7777",
        base_ref: "master",
        gh_updated_at: ~U[2026-04-25 10:00:00Z]
      })
      |> Ash.create!()

    file =
      Tracker.Nixpkgs.File
      |> Ash.Query.filter(path == "nixos/modules/services/web-servers/nginx/default.nix")
      |> Ash.read_one!()

    Tracker.Nixpkgs.ChangeFile.bulk_insert_all([%{change_id: change_id, file_id: file.id}])

    {:ok, _view, html} = live(conn, ~p"/options/services.nginx")

    assert html =~ "Recent PRs"
    assert html =~ "7777"
    assert html =~ "nginx: bump to 1.27"
    assert html =~ "pill-merged"
  end

  test "Recent PRs section omitted when no change_files intersect", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/options/services.nginx")

    refute html =~ "Recent PRs"
  end
end

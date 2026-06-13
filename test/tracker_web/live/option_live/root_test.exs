defmodule TrackerWeb.OptionLive.RootTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Tracker.Fixtures
  alias Tracker.Nixpkgs.Channel

  @sample_options %{
    "services.nginx.enable" => %{
      "declarations" => ["nixos/modules/services/web-servers/nginx/default.nix"],
      "description" => "Whether to enable Nginx Web Server.",
      "loc" => ["services", "nginx", "enable"],
      "readOnly" => false,
      "type" => "boolean",
      "default" => %{"_type" => "literalExpression", "text" => "false"}
    },
    "services.openssh.enable" => %{
      "declarations" => ["nixos/modules/services/networking/ssh/sshd.nix"],
      "description" => "Whether to enable the OpenSSH secure shell daemon.",
      "loc" => ["services", "openssh", "enable"],
      "readOnly" => false,
      "type" => "boolean",
      "default" => %{"_type" => "literalExpression", "text" => "false"}
    },
    "programs.vim.enable" => %{
      "declarations" => ["nixos/modules/programs/vim.nix"],
      "description" => "Whether to enable vim.",
      "loc" => ["programs", "vim", "enable"],
      "readOnly" => false,
      "type" => "boolean"
    },
    "enableDebugging" => %{
      "declarations" => ["nixos/modules/config/debug.nix"],
      "description" => "Whether to build with debugging enabled.",
      "loc" => ["enableDebugging"],
      "readOnly" => false,
      "type" => "boolean"
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
        revision: "rootabc1234567",
        released_at: ~U[2026-03-01 10:00:00Z]
      })

    Tracker.Nixpkgs.ChannelRevision.record_result!(cr, %{result: :success})
    cr = Tracker.Nixpkgs.ChannelRevision.record_options_result!(cr, %{options_result: :success})

    Fixtures.load_options(@sample_options, cr)

    %{channel: channel, channel_revision: cr}
  end

  test "shows top-level groups as children cards with option counts", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/options")

    assert html =~ ~s(href="/options/services")
    assert html =~ ~s(href="/options/programs")
    assert html =~ "2 options"
    assert html =~ "1 options"
  end

  test "group card names carry no leading dot at the root", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/options")

    refute html =~ ~s(<span class="leading">.</span>)
  end

  test "shows depth-1 leaf options with detail", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/options")

    assert html =~ "enableDebugging"
    assert html =~ "Whether to build with debugging enabled."
  end

  test "does not render deep options as leaves at the root", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/options")

    refute html =~ "services.nginx.enable"
  end

  test "renders no breadcrumb path bar at the root", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/options")

    refute html =~ "opt-pathbar"
  end

  test "omits Defined-in and Recent PRs sections at the root", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/options")

    refute html =~ "Recent PRs"
    refute html =~ ">Defined in</h2>"
  end

  test "lens change reloads the tree for the new channel", %{conn: conn} do
    channel2 =
      Channel.create!(%{
        name: "nixos-24.11",
        display_name: "NixOS 24.11",
        status: :active,
        is_stable: false
      })

    cr2 =
      Tracker.Nixpkgs.ChannelRevision.create!(%{
        channel_id: channel2.id,
        revision: "def456abc789012",
        released_at: ~U[2026-03-02 10:00:00Z]
      })

    Tracker.Nixpkgs.ChannelRevision.record_result!(cr2, %{result: :success})

    cr2 =
      Tracker.Nixpkgs.ChannelRevision.record_options_result!(cr2, %{options_result: :success})

    Fixtures.load_options(Map.take(@sample_options, ["programs.vim.enable"]), cr2)

    {:ok, view, _html} = live(conn, ~p"/options")

    send(view.pid, {:set_lens, channel2.name, ""})
    html = render(view)

    assert html =~ ~s(href="/options/programs")
    refute html =~ ~s(href="/options/services")
  end

  test "all-channels lens shows only a select-a-channel message", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/options")

    send(view.pid, {:set_lens, "all", ""})
    html = render(view)

    assert html =~ "Select a channel"
    refute html =~ ~s(href="/options/services")
    refute html =~ "enableDebugging"
  end

  test "all-channels lens highlights the lens pill", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/options")

    refute render(view) =~ "lens-attention"

    send(view.pid, {:set_lens, "all", ""})

    assert render(view) =~ "lens-attention"
  end

  test "selecting a channel from the all-channels state restores the tree", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/options")

    send(view.pid, {:set_lens, "all", ""})
    send(view.pid, {:set_lens, "nixos-unstable", ""})
    html = render(view)

    assert html =~ ~s(href="/options/services")
    refute html =~ "lens-attention"
  end

  test "search at the root matches the whole channel", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/options?search=enable")

    assert html =~ "Matching options"
    assert html =~ ~s(href="/options/services.nginx.enable")
    assert html =~ ~s(href="/options/programs.vim.enable")
    assert html =~ ~s(href="/options/enableDebugging")
  end

  test "search at the root shows no group cards", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/options?search=nginx")

    refute html =~ "child-card"
  end

  test "fuzzy search tolerates typos", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/options?search=nginxx")

    assert html =~ ~s(href="/options/services.nginx.enable")
    refute html =~ ~s(href="/options/programs.vim.enable")
  end

  test "dot-segment match outranks fuzzy substring matches", %{
    conn: conn,
    channel_revision: cr
  } do
    inc_options = %{
      "services.incron.enable" => %{
        "declarations" => ["x"],
        "description" => "",
        "loc" => ["services", "incron", "enable"],
        "readOnly" => false,
        "type" => "boolean"
      },
      "virtualisation.incus.enable" => %{
        "declarations" => ["x"],
        "description" => "",
        "loc" => ["virtualisation", "incus", "enable"],
        "readOnly" => false,
        "type" => "boolean"
      }
    }

    Fixtures.load_options(inc_options, cr)

    {:ok, _view, html} = live(conn, ~p"/options?search=incus")

    order = option_order(html)
    incus_idx = Enum.find_index(order, &(&1 == "virtualisation.incus.enable"))
    incron_idx = Enum.find_index(order, &(&1 == "services.incron.enable"))

    assert incus_idx, "virtualisation.incus.enable not in results"
    assert incron_idx == nil or incus_idx < incron_idx
  end

  test "search form drops the page hidden input so a no-JS search starts on page 1 (trk-278)",
       %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/options?search=enable&page=2")

    hidden_names =
      html
      |> Floki.parse_document!()
      |> Floki.find("#page-search input[type=hidden]")
      |> Enum.flat_map(&Floki.attribute(&1, "name"))

    refute "page" in hidden_names
  end

  test "searching with the all-channels lens still prompts for a channel", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/options?search=nginx")

    send(view.pid, {:set_lens, "all", ""})
    html = render(view)

    assert html =~ "Select a channel"
    refute html =~ "Matching options"
  end

  defp option_order(html) do
    ~r{<a[^>]*href="/options/([^"#?]+)"[^>]*>[^<]*</a>}
    |> Regex.scan(html)
    |> Enum.map(fn [_, name] -> name end)
  end

  test "shows message when channel has no options data", %{conn: conn} do
    channel2 =
      Channel.create!(%{
        name: "nixos-24.11",
        display_name: "NixOS 24.11",
        status: :active,
        is_stable: false
      })

    Tracker.Nixpkgs.ChannelRevision.create!(%{
      channel_id: channel2.id,
      revision: "nodata123456789",
      released_at: ~U[2026-03-02 10:00:00Z]
    })

    {:ok, view, _html} = live(conn, ~p"/options")

    send(view.pid, {:set_lens, channel2.name, ""})
    html = render(view)

    assert html =~ "doesn&#39;t have options"
  end
end

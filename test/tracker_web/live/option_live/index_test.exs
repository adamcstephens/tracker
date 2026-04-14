defmodule TrackerWeb.OptionLive.IndexTest do
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
        revision: "abc123def456789",
        released_at: ~U[2026-03-01 10:00:00Z]
      })

    Tracker.Nixpkgs.ChannelRevision.record_result!(cr, %{result: :success})
    cr = Tracker.Nixpkgs.ChannelRevision.record_options_result!(cr, %{options_result: :success})

    Fixtures.load_options(@sample_options, cr)

    # Also create unscoped options (not in any channel revision)
    mod =
      Tracker.Nixpkgs.Module
      |> Ash.Changeset.for_create(:bulk_upsert, %{display_name: "services.opttest"})
      |> Ash.create!()

    for name <- ["services.opttest.enable", "services.opttest.port"] do
      Tracker.Nixpkgs.Option
      |> Ash.Changeset.for_create(:bulk_upsert, %{name: name, module_id: mod.id})
      |> Ash.create!()
    end

    %{channel: channel, channel_revision: cr}
  end

  test "shows channel-scoped options via lens", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/options")

    # Should show options from the channel revision (loaded via lens)
    assert html =~ "services.nginx.enable"
    assert html =~ "services.openssh.enable"
    assert html =~ "programs.vim.enable"
    # Unscoped options should NOT appear (lens scopes to channel)
    refute html =~ "services.opttest.enable"
    refute html =~ "services.opttest.port"
  end

  test "no duplicate channel dropdown in the page", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/options")

    # The page should not have a revision hash input
    refute html =~ ~s(placeholder="Revision hash...")
  end

  test "search filters options within channel scope", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/options?search=nginx")

    assert html =~ "services.nginx.enable"
    refute html =~ "services.openssh.enable"
    refute html =~ "programs.vim.enable"
  end

  test "lens change reloads data", %{conn: conn} do
    # Create a second channel with different options
    channel2 =
      Channel.create!(%{
        name: "nixos-24.11",
        display_name: "NixOS 24.11",
        branch: "nixos-24.11",
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

    # Load only nginx option into channel2
    Fixtures.load_options(
      Map.take(@sample_options, ["services.nginx.enable"]),
      cr2
    )

    {:ok, view, _html} = live(conn, ~p"/options")

    # Switch lens to channel2
    send(view.pid, {:set_lens, channel2.name, ""})
    html = render(view)

    assert html =~ "services.nginx.enable"
    refute html =~ "services.openssh.enable"
  end

  test "option links navigate to module page", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/options")

    # Links should go to the module page (lens is sitewide, no need for channel params)
    assert html =~ "/modules/services.nginx#opt-services.nginx.enable"
  end

  test "module links navigate to module page", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/options")

    assert html =~ "/modules/services.nginx"
  end

  test "shows fallback notice when lens is set to 'all'", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/options")

    send(view.pid, {:set_lens, "all", ""})
    html = render(view)

    assert html =~ "Options requires a specific channel"
    assert html =~ "Showing"
  end

  test "shows message when channel has no options data", %{conn: conn} do
    channel2 =
      Channel.create!(%{
        name: "nixos-24.11",
        display_name: "NixOS 24.11",
        branch: "nixos-24.11",
        status: :active,
        is_stable: false
      })

    # Channel exists but has no revisions
    _cr2 =
      Tracker.Nixpkgs.ChannelRevision.create!(%{
        channel_id: channel2.id,
        revision: "nodata123456789",
        released_at: ~U[2026-03-02 10:00:00Z]
      })

    {:ok, view, _html} = live(conn, ~p"/options")

    # Switch to channel with no options-processed revision
    send(view.pid, {:set_lens, channel2.name, ""})
    html = render(view)

    assert html =~ "doesn&#39;t have options"
  end
end

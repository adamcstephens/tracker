defmodule TrackerWeb.OptionLive.IndexTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Tracker.Nixpkgs.OptionsWorker

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
    mod =
      Tracker.Nixpkgs.Module
      |> Ash.Changeset.for_create(:bulk_upsert, %{
        display_name: "services.opttest"
      })
      |> Ash.create!()

    for name <- [
          "services.opttest.enable",
          "services.opttest.port",
          "programs.other.setting"
        ] do
      Tracker.Nixpkgs.Option
      |> Ash.Changeset.for_create(:bulk_upsert, %{name: name, module_id: mod.id})
      |> Ash.create!()
    end

    :ok
  end

  test "renders option list with module names", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/options")

    assert html =~ "services.opttest.enable"
    assert html =~ "services.opttest.port"
    assert html =~ "programs.other.setting"
    assert html =~ "services.opttest"
  end

  test "search filters options by name", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/options?search=enable")

    assert html =~ "services.opttest.enable"
    refute html =~ "services.opttest.port"
  end

  describe "channel-scoped view" do
    setup do
      cr =
        Tracker.Nixpkgs.ChannelRevision.create!(%{
          channel: "nixos-unstable",
          revision: "abc123def456789",
          released_at: ~U[2026-03-01 10:00:00Z]
        })

      Tracker.Nixpkgs.ChannelRevision.record_result!(cr, %{result: :success})
      cr = Tracker.Nixpkgs.ChannelRevision.record_options_result!(cr, %{options_result: :success})

      OptionsWorker.write_to_database(@sample_options, cr)

      %{channel_revision: cr}
    end

    test "shows channel dropdown", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/options")

      assert html =~ "nixos-unstable"
      assert html =~ ~s(select)
    end

    test "scoping to channel shows only channel options", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/options?channel=nixos-unstable")

      assert html =~ "services.nginx.enable"
      assert html =~ "services.openssh.enable"
      assert html =~ "programs.vim.enable"
      # These options exist in the flat list but have no revisions on this channel
      refute html =~ "services.opttest.enable"
      refute html =~ "services.opttest.port"
    end

    test "search works within channel scope", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/options?channel=nixos-unstable&search=nginx")

      assert html =~ "services.nginx.enable"
      refute html =~ "services.openssh.enable"
      refute html =~ "programs.vim.enable"
    end

    test "scoping to specific revision by hash", %{conn: conn, channel_revision: cr} do
      short_rev = String.slice(cr.revision, 0, 7)
      {:ok, _view, html} = live(conn, ~p"/options?channel=nixos-unstable&rev=#{short_rev}")

      assert html =~ "services.nginx.enable"
    end

    test "revision filter only shown when channel is selected", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/options")
      refute html =~ ~s(name="rev")

      {:ok, _view, html} = live(conn, ~p"/options?channel=nixos-unstable")
      assert html =~ ~s(name="rev")
    end

    test "option links carry channel context to module page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/options?channel=nixos-unstable")

      assert html =~ "/modules/services.nginx?channel=nixos-unstable#opt-services.nginx.enable"
    end

    test "module links carry channel context", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/options?channel=nixos-unstable")

      assert html =~ "/modules/services.nginx?channel=nixos-unstable"
    end
  end
end

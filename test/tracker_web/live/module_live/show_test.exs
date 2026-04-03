defmodule TrackerWeb.ModuleLive.ShowTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Tracker.Nixpkgs.OptionsWorker

  setup do
    mod =
      Tracker.Nixpkgs.Module
      |> Ash.Changeset.for_create(:bulk_upsert, %{
        display_name: "services.modshow"
      })
      |> Ash.create!()

    package =
      Tracker.Nixpkgs.Package
      |> Ash.Changeset.for_create(:create, %{attribute: "modshow-pkg"})
      |> Ash.create!()

    option =
      Tracker.Nixpkgs.Option
      |> Ash.Changeset.for_create(:bulk_upsert, %{
        name: "services.modshow.enable",
        module_id: mod.id
      })
      |> Ash.create!()

    Tracker.Nixpkgs.OptionPackage.load!(%{option_id: option.id, package_id: package.id})

    %{module: mod, package: package, option: option}
  end

  test "renders module details", %{conn: conn, module: mod} do
    {:ok, _view, html} = live(conn, ~p"/modules/#{mod.display_name}")

    assert html =~ "services.modshow"
  end

  test "shows linked packages", %{conn: conn, module: mod} do
    {:ok, _view, html} = live(conn, ~p"/modules/#{mod.display_name}")

    assert html =~ "modshow-pkg"
  end

  test "shows options", %{conn: conn, module: mod} do
    {:ok, _view, html} = live(conn, ~p"/modules/#{mod.display_name}")

    assert html =~ "services.modshow.enable"
  end

  describe "channel-scoped view" do
    setup %{module: mod} do
      cr =
        Tracker.Nixpkgs.ChannelRevision.create!(%{
          channel: "nixos-unstable",
          revision: "mod123def456789",
          released_at: ~U[2026-03-01 10:00:00Z]
        })

      Tracker.Nixpkgs.ChannelRevision.record_result!(cr, %{result: :success})
      cr = Tracker.Nixpkgs.ChannelRevision.record_options_result!(cr, %{options_result: :success})

      # Create options that belong to this module's declaration
      options = %{
        "services.modshow.enable" => %{
          "declarations" => ["services.modshow"],
          "description" => "Whether to enable modshow.",
          "loc" => ["services", "modshow", "enable"],
          "readOnly" => false,
          "type" => "boolean",
          "default" => %{"_type" => "literalExpression", "text" => "false"}
        },
        "services.modshow.port" => %{
          "declarations" => ["services.modshow"],
          "description" => "The port for modshow.",
          "loc" => ["services", "modshow", "port"],
          "readOnly" => false,
          "type" => "16 bit unsigned integer"
        }
      }

      OptionsWorker.write_to_database(options, cr)

      # Also create an option on a different module to ensure filtering works
      other_mod =
        Tracker.Nixpkgs.Module
        |> Ash.Changeset.for_create(:bulk_upsert, %{
          display_name: "services.other"
        })
        |> Ash.create!()

      other_options = %{
        "services.other.enable" => %{
          "declarations" => ["services.other"],
          "description" => "Other service.",
          "loc" => ["services", "other", "enable"],
          "readOnly" => false,
          "type" => "boolean"
        }
      }

      OptionsWorker.write_to_database(other_options, cr)

      %{channel_revision: cr, module: mod, other_module: other_mod}
    end

    test "shows channel and revision in subtitle", %{conn: conn, module: mod} do
      {:ok, _view, html} = live(conn, "/modules/#{mod.display_name}?channel=nixos-unstable")

      assert html =~ "nixos-unstable"
      assert html =~ "mod123d"
    end

    test "shows only options from channel revision for this module", %{conn: conn, module: mod} do
      {:ok, _view, html} = live(conn, "/modules/#{mod.display_name}?channel=nixos-unstable")

      assert html =~ "services.modshow.enable"
      assert html =~ "Whether to enable modshow."
      assert html =~ "services.modshow.port"
      assert html =~ "The port for modshow."
      refute html =~ "services.other.enable"
    end

    test "back link carries channel context to options", %{conn: conn, module: mod} do
      {:ok, _view, html} = live(conn, "/modules/#{mod.display_name}?channel=nixos-unstable")

      assert html =~ "/options?channel=nixos-unstable"
    end
  end
end

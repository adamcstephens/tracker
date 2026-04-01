defmodule TrackerWeb.ModuleLive.ShowTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup do
    mod =
      Tracker.Nixpkgs.Module
      |> Ash.Changeset.for_create(:bulk_upsert, %{
        declaration: "services.modshow",
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
end

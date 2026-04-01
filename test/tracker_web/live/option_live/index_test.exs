defmodule TrackerWeb.OptionLive.IndexTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup do
    mod =
      Tracker.Nixpkgs.Module
      |> Ash.Changeset.for_create(:bulk_upsert, %{
        declaration: "services.opttest",
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
end

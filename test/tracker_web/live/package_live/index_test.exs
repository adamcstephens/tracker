defmodule TrackerWeb.PackageLive.IndexTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup do
    for name <- [
          "firefox",
          "firefox-beta",
          "firefoxpwa",
          "chromium",
          "emacs-firefox-plugin",
          "emacs.firefox-tools"
        ] do
      Tracker.Nixpkgs.Package
      |> Ash.Changeset.for_create(:create, %{attribute: name})
      |> Ash.create!()
    end

    :ok
  end

  test "search is case insensitive", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/packages?search=Firefox")

    html = render(view)
    assert html =~ "firefox"
  end

  test "exact match sorts first", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/packages?search=firefox")

    # "firefox" should appear before "firefox-beta" and "firefoxpwa"
    assert attribute_order(html) |> hd() == "firefox"
  end

  test "prefix matches sort before contains matches", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/packages?search=firefox")

    order = attribute_order(html)
    firefox_idx = Enum.find_index(order, &(&1 == "firefox"))
    plugin_idx = Enum.find_index(order, &(&1 == "emacs-firefox-plugin"))

    assert firefox_idx < plugin_idx
  end

  test "dot-segment matches sort before substring matches", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/packages?search=firefox")

    order = attribute_order(html)
    dot_segment_idx = Enum.find_index(order, &(&1 == "emacs.firefox-tools"))
    substring_idx = Enum.find_index(order, &(&1 == "emacs-firefox-plugin"))

    assert dot_segment_idx < substring_idx
  end

  defp attribute_order(html) do
    ~r/<td[^>]*>\s*(?:<a[^>]*>)?\s*([a-z][\w.-]*)\s*(?:<\/a>)?\s*<\/td>/
    |> Regex.scan(html)
    |> Enum.map(fn [_, attr] -> attr end)
  end
end

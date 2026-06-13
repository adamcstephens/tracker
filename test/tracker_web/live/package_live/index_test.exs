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

  describe "channel lens filtering" do
    setup do
      channel =
        Tracker.Nixpkgs.Channel.create!(%{
          name: "nixos-unstable",
          display_name: "nixos-unstable",
          status: :active,
          is_stable: true
        })

      cr =
        Tracker.Nixpkgs.ChannelRevision
        |> Ash.Changeset.for_create(:create, %{
          channel_id: channel.id,
          revision: "aaa1111",
          released_at: ~U[2025-01-01 00:00:00Z]
        })
        |> Ash.create!()

      pkg_in =
        Tracker.Nixpkgs.Package
        |> Ash.Changeset.for_create(:create, %{attribute: "lens-in-pkg"})
        |> Ash.create!()

      pkg_out =
        Tracker.Nixpkgs.Package
        |> Ash.Changeset.for_create(:create, %{attribute: "lens-out-pkg"})
        |> Ash.create!()

      Tracker.Nixpkgs.PackageRevision
      |> Ash.Changeset.for_create(:load, %{
        version: "1.0",
        package_id: pkg_in.id,
        channel_revision_id: cr.id
      })
      |> Ash.create!()

      %{channel: channel, pkg_in: pkg_in, pkg_out: pkg_out}
    end

    test "initial mount filters packages by default lens channel", %{
      conn: conn,
      pkg_in: pkg_in,
      pkg_out: pkg_out
    } do
      # Default lens resolves to the stable channel (nixos-unstable in this test)
      {:ok, _view, html} = live(conn, ~p"/packages")

      assert html =~ pkg_in.attribute
      refute html =~ pkg_out.attribute
    end

    test "connect_params lens overrides default on mount", %{
      conn: conn,
      pkg_in: _pkg_in,
      pkg_out: pkg_out
    } do
      # Create a second channel with pkg_out in it
      channel2 =
        Tracker.Nixpkgs.Channel.create!(%{
          name: "nixos-24.11-cp",
          display_name: "nixos-24.11-cp",
          status: :active,
          is_stable: false
        })

      cr2 =
        Tracker.Nixpkgs.ChannelRevision
        |> Ash.Changeset.for_create(:create, %{
          channel_id: channel2.id,
          revision: "ccc3333",
          released_at: ~U[2025-01-03 00:00:00Z]
        })
        |> Ash.create!()

      Tracker.Nixpkgs.PackageRevision
      |> Ash.Changeset.for_create(:load, %{
        version: "3.0",
        package_id: pkg_out.id,
        channel_revision_id: cr2.id
      })
      |> Ash.create!()

      # Simulate JS connect_params carrying the lens from a previous page
      conn = Phoenix.LiveViewTest.put_connect_params(conn, %{"_lens_channel" => channel2.name})
      {:ok, _view, html} = live(conn, ~p"/packages")

      assert html =~ pkg_out.attribute
    end

    test "lens change reloads data filtered by new channel", %{
      conn: conn,
      pkg_in: _pkg_in,
      pkg_out: pkg_out
    } do
      # Create a second channel with pkg_out in it
      channel2 =
        Tracker.Nixpkgs.Channel.create!(%{
          name: "nixos-24.11",
          display_name: "nixos-24.11",
          status: :active,
          is_stable: false
        })

      cr2 =
        Tracker.Nixpkgs.ChannelRevision
        |> Ash.Changeset.for_create(:create, %{
          channel_id: channel2.id,
          revision: "bbb2222",
          released_at: ~U[2025-01-02 00:00:00Z]
        })
        |> Ash.create!()

      Tracker.Nixpkgs.PackageRevision
      |> Ash.Changeset.for_create(:load, %{
        version: "2.0",
        package_id: pkg_out.id,
        channel_revision_id: cr2.id
      })
      |> Ash.create!()

      {:ok, view, _html} = live(conn, ~p"/packages")

      # Switch lens to channel2
      send(view.pid, {:set_lens, channel2.name, ""})
      html = render(view)

      assert html =~ pkg_out.attribute
    end
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

  describe "fuzzy matching" do
    setup do
      for name <- ["python311", "python312", "numpy", "numpy-stubs"] do
        Tracker.Nixpkgs.Package
        |> Ash.Changeset.for_create(:create, %{attribute: name})
        |> Ash.create!()
      end

      :ok
    end

    test "period-separated version finds dot-stripped attribute (trk-211)", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/packages?search=python3.11")

      assert html =~ "python311"
    end

    test "typo finds intended attribute", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/packages?search=nuympy")

      assert html =~ "numpy"
    end
  end

  describe "discovered column" do
    test "renders 'Discovered' column header", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/packages")
      assert html =~ "Discovered"
    end

    test "default sort lists most recently discovered packages first", %{conn: conn} do
      # Setup creates 6 packages in order; the last one inserted should appear first.
      {:ok, _view, html} = live(conn, ~p"/packages")

      assert attribute_order(html) |> hd() == "emacs.firefox-tools"
    end

    test "sort_by=inserted_at&sort_dir=asc reverses default order", %{conn: conn} do
      {:ok, _view, html} =
        live(conn, ~p"/packages?sort_by=inserted_at&sort_dir=asc")

      assert attribute_order(html) |> hd() == "firefox"
    end
  end

  describe "search resets pagination (trk-278)" do
    test "search form drops the page hidden input so a no-JS search starts on page 1", %{
      conn: conn
    } do
      {:ok, _view, html} = live(conn, ~p"/packages?page=2")

      hidden_names =
        html
        |> Floki.parse_document!()
        |> Floki.find("#page-search input[type=hidden]")
        |> Enum.flat_map(&Floki.attribute(&1, "name"))

      refute "page" in hidden_names
    end
  end

  describe "count-less pagination (trk-314)" do
    setup do
      for n <- 1..20 do
        Tracker.Nixpkgs.Package
        |> Ash.Changeset.for_create(:create, %{attribute: "pagepkg-#{n}"})
        |> Ash.create!()
      end

      :ok
    end

    test "footer shows the current page without a total", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/packages")

      assert html =~ "Page 1"
      refute html =~ "Page 1 of"
      assert html =~ ~s(href="/packages?page=2")
    end

    test "later pages keep prev/next without a total", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/packages?page=2")

      assert html =~ "Page 2"
      refute html =~ "Page 2 of"
    end
  end

  defp attribute_order(html) do
    ~r/<td[^>]*>\s*(?:<a[^>]*>)?\s*([a-z][\w.-]*)\s*(?:<\/a>)?\s*<\/td>/
    |> Regex.scan(html)
    |> Enum.map(fn [_, attr] -> attr end)
  end
end

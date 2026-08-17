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
          name: "nixos-pkgindex",
          display_name: "nixos-pkgindex",
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

      Tracker.Fixtures.apply_package_revision!(cr, [{pkg_in, "1.0"}])

      %{channel: channel, pkg_in: pkg_in, pkg_out: pkg_out}
    end

    test "initial mount filters packages by default lens channel", %{
      conn: conn,
      pkg_in: pkg_in,
      pkg_out: pkg_out
    } do
      # Default lens resolves to the stable channel (nixos-pkgindex in this test)
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
          name: "nixos-24.64-cp",
          display_name: "nixos-24.64-cp",
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

      Tracker.Fixtures.apply_package_revision!(cr2, [{pkg_out, "3.0"}])

      {:ok, _view, html} = live(conn, ~p"/packages?channel=#{channel2.name}")

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
          name: "nixos-24.64",
          display_name: "nixos-24.64",
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

      Tracker.Fixtures.apply_package_revision!(cr2, [{pkg_out, "2.0"}])

      {:ok, view, _html} = live(conn, ~p"/packages")

      # Switch lens to channel2
      {:ok, _view, html} = switch_lens(conn, view, channel2.name)

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

  describe "current description column" do
    test "shows a package's current description from the metadata channel", %{conn: conn} do
      channel =
        Tracker.Nixpkgs.Channel.create!(%{
          name: "nixos-unstable-small",
          display_name: "nixos-unstable-small",
          status: :active,
          is_stable: true
        })

      cr =
        Tracker.Nixpkgs.ChannelRevision
        |> Ash.Changeset.for_create(:create, %{
          channel_id: channel.id,
          revision: "ddd4444",
          released_at: ~U[2025-01-04 00:00:00Z]
        })
        |> Ash.create!()

      pkg =
        Tracker.Nixpkgs.Package
        |> Ash.Changeset.for_create(:create, %{attribute: "desc-col-pkg"})
        |> Ash.create!()

      Tracker.Fixtures.apply_package_revision!(cr, [
        {pkg, %{version: "9.9", description: "A current-state description"}}
      ])

      {:ok, _view, html} = live(conn, ~p"/packages?channel=#{channel.name}")

      assert html =~ "desc-col-pkg"
      assert html =~ "A current-state description"
    end
  end

  describe "lens-aware descriptions (trk-352)" do
    setup do
      meta_channel =
        Tracker.Nixpkgs.Channel.create!(%{
          name: Tracker.Ingestion.StepGraph.metadata_channel(),
          display_name: "unstable-small",
          status: :active,
          is_stable: false
        })

      meta_cr =
        Tracker.Nixpkgs.ChannelRevision
        |> Ash.Changeset.for_create(:create, %{
          channel_id: meta_channel.id,
          revision: "eee5555",
          released_at: ~U[2025-01-05 00:00:00Z]
        })
        |> Ash.create!()

      lens_channel =
        Tracker.Nixpkgs.Channel.create!(%{
          name: "nixos-24.65",
          display_name: "nixos-24.65",
          status: :active,
          is_stable: true
        })

      lens_cr =
        Tracker.Nixpkgs.ChannelRevision
        |> Ash.Changeset.for_create(:create, %{
          channel_id: lens_channel.id,
          revision: "fff6666",
          released_at: ~U[2025-01-06 00:00:00Z]
        })
        |> Ash.create!()

      pkg_both =
        Tracker.Nixpkgs.Package
        |> Ash.Changeset.for_create(:create, %{attribute: "lens-desc-pkg"})
        |> Ash.create!()

      pkg_premeta =
        Tracker.Nixpkgs.Package
        |> Ash.Changeset.for_create(:create, %{attribute: "premeta-desc-pkg"})
        |> Ash.create!()

      Tracker.Fixtures.apply_package_revision!(meta_cr, [
        {pkg_both, %{version: "1.0", description: "Meta description"}},
        {pkg_premeta, %{version: "1.0", description: "Fallback description"}}
      ])

      Tracker.Fixtures.apply_package_revision!(lens_cr, [
        {pkg_both, %{version: "1.0", description: "Lens description"}},
        {pkg_premeta, "1.0"}
      ])

      %{lens_channel: lens_channel}
    end

    test "prefers the lens channel's description", %{conn: conn, lens_channel: lens_channel} do
      {:ok, _view, html} = live(conn, ~p"/packages?channel=#{lens_channel.name}")

      assert html =~ "Lens description"
      refute html =~ "Meta description"
    end

    test "falls back to the metadata channel when the lens span has no metadata", %{
      conn: conn,
      lens_channel: lens_channel
    } do
      {:ok, _view, html} = live(conn, ~p"/packages?channel=#{lens_channel.name}")

      assert html =~ "premeta-desc-pkg"
      assert html =~ "Fallback description"
    end

    test "all-channels lens reads from the metadata channel", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/packages?channel=all")

      assert html =~ "Meta description"
      refute html =~ "Lens description"
    end

    test "lens switch swaps the shown description", %{conn: conn, lens_channel: lens_channel} do
      {:ok, view, html} = live(conn, ~p"/packages?channel=#{lens_channel.name}")

      assert html =~ "Lens description"

      {:ok, _view, html} = switch_lens(conn, view, "all")

      assert html =~ "Meta description"
      refute html =~ "Lens description"
    end
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

  describe "row list" do
    test "each row links to the package", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/packages")

      hrefs =
        html
        |> Floki.parse_document!()
        |> Floki.find("#packages a.row-link")
        |> Enum.flat_map(&Floki.attribute(&1, "href"))

      assert "/packages/firefox" in hrefs
    end

    test "shows when each package was discovered", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/packages")

      meta =
        html
        |> Floki.parse_document!()
        |> Floki.find("#packages .row-meta")
        |> Floki.text()

      assert meta =~ ~r/\d{4}-\d{2}-\d{2} \d{2}:\d{2}/
    end
  end

  describe "ordering" do
    test "lists most recently discovered packages first", %{conn: conn} do
      # Setup creates 6 packages in order; the last one inserted should appear first.
      {:ok, _view, html} = live(conn, ~p"/packages")

      assert attribute_order(html) |> hd() == "emacs.firefox-tools"
    end

    test "sort params no longer reorder the list", %{conn: conn} do
      {:ok, _view, html} =
        live(conn, ~p"/packages?sort_by=inserted_at&sort_dir=asc")

      assert attribute_order(html) |> hd() == "emacs.firefox-tools"
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
    html
    |> Floki.parse_document!()
    |> Floki.find("#packages .row-label")
    |> Enum.map(&(&1 |> Floki.text() |> String.trim()))
  end
end

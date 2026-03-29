defmodule TrackerWeb.PackageLive.ShowTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup do
    cr1 =
      Ash.create!(Tracker.Nixpkgs.ChannelRevision, %{
        channel: "nixos-unstable",
        revision: "abc123def456789",
        released_at: ~U[2026-03-01 10:00:00Z]
      })

    cr2 =
      Ash.create!(Tracker.Nixpkgs.ChannelRevision, %{
        channel: "nixos-24.11",
        revision: "def456abc789012",
        released_at: ~U[2026-03-15 10:00:00Z]
      })

    package =
      Tracker.Nixpkgs.Package
      |> Ash.Changeset.for_create(:create, %{attribute: "hello"})
      |> Ash.create!()

    Tracker.Nixpkgs.PackageRevision
    |> Ash.Changeset.for_create(:load, %{
      version: "2.12.1",
      package_id: package.id,
      channel_revision_id: cr1.id
    })
    |> Ash.create!()

    Tracker.Nixpkgs.PackageRevision
    |> Ash.Changeset.for_create(:load, %{
      version: "2.13.0",
      package_id: package.id,
      channel_revision_id: cr2.id
    })
    |> Ash.create!()

    %{package: package, cr1: cr1, cr2: cr2}
  end

  test "displays package attribute as heading", %{conn: conn, package: package} do
    {:ok, _view, html} = live(conn, ~p"/packages/#{package.attribute}")

    assert html =~ "hello"
  end

  test "displays revision with version and channel", %{conn: conn, package: package} do
    {:ok, _view, html} = live(conn, ~p"/packages/#{package.attribute}")

    assert html =~ "2.12.1"
    assert html =~ "nixos-unstable"
  end

  test "displays truncated revision hash linked to github", %{conn: conn, package: package} do
    {:ok, _view, html} = live(conn, ~p"/packages/#{package.attribute}")

    assert html =~ "abc123d"
    assert html =~ "https://github.com/NixOS/nixpkgs/commit/abc123def456789"
  end

  test "shows empty state when no revisions", %{conn: conn} do
    empty_package =
      Tracker.Nixpkgs.Package
      |> Ash.Changeset.for_create(:create, %{attribute: "empty-pkg"})
      |> Ash.create!()

    {:ok, _view, html} = live(conn, ~p"/packages/#{empty_package.attribute}")

    assert html =~ "No revisions found"
  end

  test "displays released_at column", %{conn: conn, package: package} do
    {:ok, _view, html} = live(conn, ~p"/packages/#{package.attribute}")

    assert html =~ "Released"
    assert html =~ "2026-03-01 10:00"
  end

  test "default sort is released_at descending", %{conn: conn, package: package} do
    {:ok, _view, html} = live(conn, ~p"/packages/#{package.attribute}")

    # cr2 (2026-03-15) should appear before cr1 (2026-03-01)
    assert version_order(html) == ["2.13.0", "2.12.1"]
  end

  test "sort by version ascending via URL param", %{conn: conn, package: package} do
    {:ok, _view, html} =
      live(conn, ~p"/packages/#{package.attribute}?sort_by=version&sort_dir=asc")

    assert version_order(html) == ["2.12.1", "2.13.0"]
  end

  test "clicking sort header updates URL", %{conn: conn, package: package} do
    {:ok, view, _html} = live(conn, ~p"/packages/#{package.attribute}")

    # Click version header to sort asc
    html = view |> element("th[phx-value-field=version]") |> render_click()

    assert_patched(view, ~p"/packages/#{package.attribute}?sort_by=version&sort_dir=asc")
    assert version_order(html) == ["2.12.1", "2.13.0"]

    # Click again to toggle to desc (sort_dir=desc is default so omitted from URL)
    html = view |> element("th[phx-value-field=version]") |> render_click()

    assert_patched(view, ~p"/packages/#{package.attribute}?sort_by=version")
    assert version_order(html) == ["2.13.0", "2.12.1"]
  end

  test "filter by channel via URL param", %{conn: conn, package: package} do
    {:ok, _view, html} = live(conn, ~p"/packages/#{package.attribute}?channel=nixos-unstable")

    assert html =~ "2.12.1"
    refute html =~ "2.13.0"
  end

  test "filter by version via URL param", %{conn: conn, package: package} do
    {:ok, _view, html} = live(conn, ~p"/packages/#{package.attribute}?version=2.12")

    assert html =~ "2.12.1"
    refute html =~ "2.13.0"
  end

  test "shows family siblings when package has a family", %{conn: conn} do
    family =
      Tracker.Nixpkgs.PackageFamily
      |> Ash.Changeset.for_create(:bulk_upsert, %{name: "numpy", ecosystem: "python"})
      |> Ash.create!()

    Tracker.Nixpkgs.Package
    |> Ash.Changeset.for_create(:bulk_upsert, %{
      attribute: "python313Packages.numpy",
      package_family_id: family.id,
      package_set: "python313Packages",
      set_version: "3.13"
    })
    |> Ash.create!()

    Tracker.Nixpkgs.Package
    |> Ash.Changeset.for_create(:bulk_upsert, %{
      attribute: "python312Packages.numpy",
      package_family_id: family.id,
      package_set: "python312Packages",
      set_version: "3.12"
    })
    |> Ash.create!()

    {:ok, _view, html} = live(conn, ~p"/packages/python313Packages.numpy")

    assert html =~ "Also available in"
    assert html =~ "python312Packages"
    assert html =~ "(3.12)"
  end

  test "does not show siblings section for packages without a family", %{
    conn: conn,
    package: package
  } do
    {:ok, _view, html} = live(conn, ~p"/packages/#{package.attribute}")

    refute html =~ "Also available in"
  end

  describe "changes only toggle" do
    setup %{package: package} do
      # Add a third unstable revision with same version (noop bump)
      cr3 =
        Ash.create!(Tracker.Nixpkgs.ChannelRevision, %{
          channel: "nixos-unstable",
          revision: "aaa111bbb222333",
          released_at: ~U[2026-03-10 10:00:00Z]
        })

      Tracker.Nixpkgs.PackageRevision
      |> Ash.Changeset.for_create(:load, %{
        version: "2.12.1",
        package_id: package.id,
        channel_revision_id: cr3.id
      })
      |> Ash.create!()

      # Add a fourth unstable revision with a new version (real change)
      cr4 =
        Ash.create!(Tracker.Nixpkgs.ChannelRevision, %{
          channel: "nixos-unstable",
          revision: "ccc333ddd444555",
          released_at: ~U[2026-03-20 10:00:00Z]
        })

      Tracker.Nixpkgs.PackageRevision
      |> Ash.Changeset.for_create(:load, %{
        version: "2.14.0",
        package_id: package.id,
        channel_revision_id: cr4.id
      })
      |> Ash.create!()

      %{cr3: cr3, cr4: cr4}
    end

    test "by default, noop version bumps are hidden", %{conn: conn, package: package} do
      {:ok, _view, html} = live(conn, ~p"/packages/#{package.attribute}")

      versions = version_order(html)

      # Should show: cr1(2.12.1 first unstable), cr2(2.13.0 first 24.11), cr4(2.14.0 changed unstable)
      # Should hide: cr3(2.12.1 same as cr1 in unstable)
      assert length(versions) == 3
      assert "2.12.1" in versions
      assert "2.13.0" in versions
      assert "2.14.0" in versions
    end

    test "with all_revisions toggle, all revisions are shown", %{conn: conn, package: package} do
      {:ok, _view, html} =
        live(conn, ~p"/packages/#{package.attribute}?all_revisions=true")

      # 4 revisions total: cr1(2.12.1), cr3(2.12.1), cr2(2.13.0), cr4(2.14.0)
      assert length(version_order(html)) == 4
    end

    test "toggle checkbox shows all revisions", %{conn: conn, package: package} do
      {:ok, view, _html} = live(conn, ~p"/packages/#{package.attribute}")

      html =
        view
        |> element("form.revision-filters")
        |> render_change(%{"all_revisions" => "true"})

      versions = version_order(html)
      assert length(versions) == 4
    end

    test "all_revisions is preserved in URL after sort", %{conn: conn, package: package} do
      {:ok, view, _html} =
        live(conn, ~p"/packages/#{package.attribute}?all_revisions=true")

      # Click sort to verify all_revisions survives navigation
      view |> element("th[phx-value-field=version]") |> render_click()

      url = assert_patch(view)
      assert url =~ "all_revisions=true"
      assert url =~ "sort_by=version"
      assert url =~ "sort_dir=asc"
    end
  end

  defp version_order(html) do
    ~r/<td[^>]*>\s*(\d+\.\d+\.\d+)\s*<\/td>/
    |> Regex.scan(html)
    |> Enum.map(fn [_, version] -> version end)
  end
end

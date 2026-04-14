defmodule TrackerWeb.PackageLive.ShowTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Tracker.Nixpkgs.Channel

  setup do
    channel_unstable =
      Channel.create!(%{
        name: "nixos-unstable",
        display_name: "NixOS Unstable",
        branch: "nixos-unstable",
        status: :active,
        is_stable: true
      })

    channel_stable =
      Channel.create!(%{
        name: "nixos-24.11",
        display_name: "NixOS 24.11",
        branch: "release-24.11",
        status: :active,
        is_stable: false
      })

    cr1 =
      Ash.create!(Tracker.Nixpkgs.ChannelRevision, %{
        channel_id: channel_unstable.id,
        revision: "abc123def456789",
        released_at: ~U[2026-03-01 10:00:00Z]
      })

    cr2 =
      Ash.create!(Tracker.Nixpkgs.ChannelRevision, %{
        channel_id: channel_stable.id,
        revision: "def456abc789012",
        released_at: ~U[2026-03-15 10:00:00Z]
      })

    package =
      Tracker.Nixpkgs.Package
      |> Ash.Changeset.for_create(:create, %{attribute: "pkgshow-hello"})
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

    %{
      package: package,
      cr1: cr1,
      cr2: cr2,
      channel_unstable: channel_unstable,
      channel_stable: channel_stable
    }
  end

  test "updates when a new revision is broadcast", %{
    conn: conn,
    package: package,
    channel_unstable: channel_unstable
  } do
    {:ok, view, html} = live(conn, ~p"/packages/#{package.attribute}")

    refute html =~ "3.0.0"

    cr3 =
      Ash.create!(Tracker.Nixpkgs.ChannelRevision, %{
        channel_id: channel_unstable.id,
        revision: "new111aaa222333",
        released_at: ~U[2026-03-20 10:00:00Z]
      })

    Tracker.Nixpkgs.PackageRevision
    |> Ash.Changeset.for_create(:load, %{
      version: "3.0.0",
      package_id: package.id,
      channel_revision_id: cr3.id
    })
    |> Ash.create!()

    Phoenix.PubSub.broadcast(
      Tracker.PubSub,
      "channel_revisions:nixos-unstable",
      {:channel_revision_completed,
       %{channel_name: "nixos-unstable", revision: "new111aaa222333"}}
    )

    html = render(view)
    assert html =~ "3.0.0"
  end

  test "displays package attribute as heading", %{conn: conn, package: package} do
    {:ok, _view, html} = live(conn, ~p"/packages/#{package.attribute}")

    assert html =~ "pkgshow-hello"
  end

  test "displays revision with version and channel", %{conn: conn, package: package} do
    {:ok, _view, html} = live(conn, ~p"/packages/#{package.attribute}")

    # Default lens is nixos-unstable (the stable channel in this test)
    assert html =~ "2.12.1"
    assert html =~ "nixos-unstable"
  end

  test "displays truncated revision hash linked to revision show page", %{
    conn: conn,
    package: package
  } do
    {:ok, _view, html} = live(conn, ~p"/packages/#{package.attribute}")

    assert html =~ "abc123d"
    assert html =~ "/channels/nixos-unstable/revisions/abc123def456789"
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

    # Only nixos-unstable revision is shown (lens default)
    assert version_order(html) == ["2.12.1"]
  end

  test "released_at descending sorts by temporal order across months", %{
    conn: conn,
    channel_unstable: channel_unstable
  } do
    pkg =
      Tracker.Nixpkgs.Package
      |> Ash.Changeset.for_create(:create, %{attribute: "crossmonth-pkg"})
      |> Ash.create!()

    cr_aug =
      Ash.create!(Tracker.Nixpkgs.ChannelRevision, %{
        channel_id: channel_unstable.id,
        revision: "aug30aaa111222",
        released_at: ~U[2025-08-30 17:40:00Z]
      })

    cr_sep =
      Ash.create!(Tracker.Nixpkgs.ChannelRevision, %{
        channel_id: channel_unstable.id,
        revision: "sep29bbb333444",
        released_at: ~U[2025-09-29 10:56:00Z]
      })

    Tracker.Nixpkgs.PackageRevision
    |> Ash.Changeset.for_create(:load, %{
      version: "6.16.0",
      package_id: pkg.id,
      channel_revision_id: cr_aug.id
    })
    |> Ash.create!()

    Tracker.Nixpkgs.PackageRevision
    |> Ash.Changeset.for_create(:load, %{
      version: "6.17.0",
      package_id: pkg.id,
      channel_revision_id: cr_sep.id
    })
    |> Ash.create!()

    {:ok, _view, html} = live(conn, ~p"/packages/crossmonth-pkg")

    # Sep 29 is newer than Aug 30, so 6.17.0 must appear first
    assert version_order(html) == ["6.17.0", "6.16.0"]
  end

  test "sort by version ascending via URL param", %{conn: conn, package: package} do
    {:ok, _view, html} =
      live(conn, ~p"/packages/#{package.attribute}?sort_by=version&sort_dir=asc")

    # Only one revision in the lens channel (nixos-unstable)
    assert version_order(html) == ["2.12.1"]
  end

  test "clicking sort header updates URL", %{conn: conn, package: package} do
    {:ok, view, _html} = live(conn, ~p"/packages/#{package.attribute}")

    # Click version header to sort asc
    html = view |> element("th[phx-value-field=version]") |> render_click()

    assert_patched(view, ~p"/packages/#{package.attribute}?sort_by=version&sort_dir=asc")
    assert version_order(html) == ["2.12.1"]
  end

  test "lens change reloads revision data", %{
    conn: conn,
    package: package,
    channel_stable: channel_stable
  } do
    {:ok, view, html} = live(conn, ~p"/packages/#{package.attribute}")

    # Default lens shows nixos-unstable (2.12.1)
    assert html =~ "2.12.1"
    refute html =~ "2.13.0"

    # Switch lens to nixos-24.11
    send(view.pid, {:set_lens, channel_stable.name, ""})
    html = render(view)

    assert html =~ "2.13.0"
    refute html =~ "2.12.1"
  end

  test "no duplicate channel dropdown", %{conn: conn, package: package} do
    {:ok, _view, html} = live(conn, ~p"/packages/#{package.attribute}")

    # The revision filter form should not have a channel select
    refute html =~ ~s(aria-label="Filter by channel")
  end

  test "filter by version via URL param", %{conn: conn, package: package} do
    {:ok, _view, html} = live(conn, ~p"/packages/#{package.attribute}?version=2.12")

    assert html =~ "2.12.1"
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

  test "shows variant siblings when package has a variant group", %{conn: conn} do
    group =
      Tracker.Nixpkgs.PackageVariantGroup
      |> Ash.Changeset.for_create(:bulk_upsert, %{
        position: "pkgs/libraries/ffmpeg/generic.nix:100"
      })
      |> Ash.create!()

    Tracker.Nixpkgs.Package
    |> Ash.Changeset.for_create(:bulk_upsert, %{
      attribute: "ffmpeg_7",
      package_variant_group_id: group.id
    })
    |> Ash.create!()

    Tracker.Nixpkgs.Package
    |> Ash.Changeset.for_create(:bulk_upsert, %{
      attribute: "ffmpeg_8",
      package_variant_group_id: group.id
    })
    |> Ash.create!()

    {:ok, _view, html} = live(conn, ~p"/packages/ffmpeg_7")

    assert html =~ "Variants"
    assert html =~ "ffmpeg_8"
  end

  test "does not show variants section for packages without a variant group", %{
    conn: conn,
    package: package
  } do
    {:ok, _view, html} = live(conn, ~p"/packages/#{package.attribute}")

    refute html =~ "Variants"
  end

  describe "linked options" do
    setup %{package: package, cr1: cr1} do
      mod =
        Tracker.Nixpkgs.Module
        |> Ash.Changeset.for_create(:bulk_upsert, %{
          display_name: "services.hello"
        })
        |> Ash.create!()

      option =
        Tracker.Nixpkgs.Option
        |> Ash.Changeset.for_create(:bulk_upsert, %{
          name: "services.hello.enable",
          module_id: mod.id
        })
        |> Ash.create!()

      Tracker.Nixpkgs.OptionPackage.load!(%{
        option_id: option.id,
        package_id: package.id,
        module_id: mod.id
      })

      Tracker.Nixpkgs.OptionRevision
      |> Ash.Changeset.for_create(:load, %{
        option_id: option.id,
        channel_revision_id: cr1.id,
        type: "boolean",
        description: "Whether to enable hello service."
      })
      |> Ash.create!()

      %{option: option, module: mod}
    end

    test "shows linked options section", %{conn: conn, package: package} do
      {:ok, _view, html} = live(conn, ~p"/packages/#{package.attribute}")

      assert html =~ "NixOS Options"
      assert html =~ "services.hello.enable"
    end

    test "shows option type and description", %{conn: conn, package: package} do
      {:ok, _view, html} = live(conn, ~p"/packages/#{package.attribute}")

      assert html =~ "boolean"
      assert html =~ "Whether to enable hello service."
    end

    test "option links to module show page", %{conn: conn, package: package, module: mod} do
      {:ok, _view, html} = live(conn, ~p"/packages/#{package.attribute}")

      assert html =~ ~s|/modules/#{mod.display_name}#opt-services.hello.enable|
    end
  end

  describe "changes only toggle" do
    setup %{package: package, channel_unstable: channel_unstable} do
      # Add a third unstable revision with same version (noop bump)
      cr3 =
        Ash.create!(Tracker.Nixpkgs.ChannelRevision, %{
          channel_id: channel_unstable.id,
          revision: "noop111bbb222333",
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
          channel_id: channel_unstable.id,
          revision: "chg333ddd444555",
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

      # Lens defaults to nixos-unstable. Shows version changes only:
      # cr1(2.12.1 first), cr4(2.14.0 changed) — cr3 is noop (same 2.12.1)
      assert length(versions) == 2
      assert "2.12.1" in versions
      assert "2.14.0" in versions
    end

    test "with all_revisions toggle, all revisions are shown", %{conn: conn, package: package} do
      {:ok, _view, html} =
        live(conn, ~p"/packages/#{package.attribute}?all_revisions=true")

      # 3 unstable revisions: cr1(2.12.1), cr3(2.12.1), cr4(2.14.0)
      assert length(version_order(html)) == 3
    end

    test "toggle checkbox shows all revisions", %{conn: conn, package: package} do
      {:ok, view, _html} = live(conn, ~p"/packages/#{package.attribute}")

      html =
        view
        |> element("form.revision-filters")
        |> render_change(%{"all_revisions" => "true"})

      versions = version_order(html)
      # 3 unstable revisions
      assert length(versions) == 3
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

defmodule TrackerWeb.PackageLive.ShowTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Tracker.Nixpkgs.Channel

  setup do
    channel_unstable =
      Channel.create!(%{
        name: "nixos-unstable",
        display_name: "NixOS Unstable",
        status: :active,
        is_stable: true
      })

    channel_stable =
      Channel.create!(%{
        name: "nixos-24.11",
        display_name: "NixOS 24.11",
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

    Tracker.Fixtures.apply_package_revision!(cr1, [{package, "2.12.1"}])
    Tracker.Fixtures.apply_package_revision!(cr2, [{package, "2.13.0"}])

    %{
      package: package,
      cr1: cr1,
      cr2: cr2,
      channel_unstable: channel_unstable,
      channel_stable: channel_stable
    }
  end

  describe "package metadata by lens" do
    setup %{package: package, channel_stable: channel_stable} do
      channel_meta =
        Channel.create!(%{
          name: "nixos-unstable-small",
          display_name: "NixOS Unstable Small",
          status: :active,
          is_stable: false
        })

      cr_meta =
        Ash.create!(Tracker.Nixpkgs.ChannelRevision, %{
          channel_id: channel_meta.id,
          revision: "meta111bbb222333",
          released_at: ~U[2026-03-18 10:00:00Z]
        })

      Tracker.Fixtures.apply_package_revision!(cr_meta, [
        {package, %{version: "2.14.0", description: "Meta-channel description"}}
      ])

      cr_stable_meta =
        Ash.create!(Tracker.Nixpkgs.ChannelRevision, %{
          channel_id: channel_stable.id,
          revision: "stab111ccc222333",
          released_at: ~U[2026-03-19 10:00:00Z]
        })

      Tracker.Fixtures.apply_package_revision!(cr_stable_meta, [
        {package, %{version: "2.13.0", description: "Stable-channel description"}}
      ])

      %{channel_meta: channel_meta}
    end

    test "a specific channel lens shows that channel's metadata", %{
      conn: conn,
      package: package
    } do
      {:ok, _view, html} =
        live(conn, ~p"/packages/#{package.attribute}?lens_channel=nixos-24.11")

      assert html =~ "Stable-channel description"
      refute html =~ "Meta-channel description"
    end

    test "the all-channels lens shows metadata-channel metadata", %{
      conn: conn,
      package: package
    } do
      {:ok, _view, html} = live(conn, ~p"/packages/#{package.attribute}?lens_channel=all")

      assert html =~ "Meta-channel description"
      refute html =~ "Stable-channel description"
    end

    test "falls back to the metadata channel when the lens channel span has no metadata", %{
      conn: conn,
      package: package
    } do
      {:ok, _view, html} =
        live(conn, ~p"/packages/#{package.attribute}?lens_channel=nixos-unstable")

      assert html =~ "Meta-channel description"
    end

    test "a lens switch reloads metadata", %{
      conn: conn,
      package: package,
      channel_stable: channel_stable
    } do
      {:ok, view, html} = live(conn, ~p"/packages/#{package.attribute}?lens_channel=all")

      assert html =~ "Meta-channel description"

      send(view.pid, {:set_lens, channel_stable.name, ""})
      html = render(view)

      assert html =~ "Stable-channel description"
      refute html =~ "Meta-channel description"
    end
  end

  describe "extended metadata" do
    setup %{cr1: cr1} do
      rich =
        Tracker.Nixpkgs.Package
        |> Ash.Changeset.for_create(:create, %{attribute: "pkgshow-rich"})
        |> Ash.create!()

      Tracker.Fixtures.apply_package_revision!(cr1, [
        {rich,
         %{
           version: "1.0",
           description: "Rich metadata package",
           pname: "rich-pname",
           outputs: ["man", "out"],
           default_output: "out",
           long_description: "First rich line.\nSecond rich line.",
           main_program: "richbin",
           broken: true,
           unfree: true,
           insecure: true,
           unsupported: true,
           known_vulnerabilities: ["CVE-2024-0001: overflow"],
           platforms: ["x86_64-linux", "mips64n32"],
           bad_platforms: ["darwin"],
           changelog: ["https://example.com/NEWS", "https://example.com/CHANGELOG"],
           download_page: "https://example.com/download",
           source_provenance: ["binaryNativeCode"]
         }}
      ])

      %{rich: rich}
    end

    test "shows the long description preserving line breaks", %{conn: conn, rich: rich} do
      {:ok, _view, html} = live(conn, ~p"/packages/#{rich.attribute}")

      assert html =~ "First rich line."
      assert html =~ "Second rich line."
      assert html =~ "white-space: pre-line"
    end

    test "shows outputs with the default output", %{conn: conn, rich: rich} do
      {:ok, _view, html} = live(conn, ~p"/packages/#{rich.attribute}")

      assert html =~ "Outputs"
      assert html =~ "man, out"
      assert html =~ "default: out"
    end

    test "shows the main program", %{conn: conn, rich: rich} do
      {:ok, _view, html} = live(conn, ~p"/packages/#{rich.attribute}")

      assert html =~ "Main program"
      assert html =~ "richbin"
    end

    test "shows availability badges when flags are true", %{conn: conn, rich: rich} do
      {:ok, _view, html} = live(conn, ~p"/packages/#{rich.attribute}")

      assert html =~ "<mark>broken</mark>"
      assert html =~ "<mark>unfree</mark>"
      assert html =~ "<mark>insecure</mark>"
      assert html =~ "<mark>unsupported</mark>"
    end

    test "hides availability badges when flags are absent", %{conn: conn, package: package} do
      {:ok, _view, html} = live(conn, ~p"/packages/#{package.attribute}")

      refute html =~ "<mark>broken</mark>"
      refute html =~ "<mark>unfree</mark>"
    end

    test "shows known vulnerabilities", %{conn: conn, rich: rich} do
      {:ok, _view, html} = live(conn, ~p"/packages/#{rich.attribute}")

      assert html =~ "CVE-2024-0001: overflow"
    end

    test "shows platforms and bad platforms collapsed", %{conn: conn, rich: rich} do
      {:ok, _view, html} = live(conn, ~p"/packages/#{rich.attribute}")

      assert html =~ "<details"
      assert html =~ "Platforms (2)"
      assert html =~ "x86_64-linux, mips64n32"
      assert html =~ "Bad platforms (1)"
      assert html =~ "darwin"
    end

    test "links changelog and download page", %{conn: conn, rich: rich} do
      {:ok, _view, html} = live(conn, ~p"/packages/#{rich.attribute}")

      assert html =~ "Changelog"
      assert html =~ ~s|href="https://example.com/NEWS"|
      assert html =~ ~s|href="https://example.com/CHANGELOG"|
      assert html =~ "Download page"
      assert html =~ ~s|href="https://example.com/download"|
    end

    test "shows source provenance", %{conn: conn, rich: rich} do
      {:ok, _view, html} = live(conn, ~p"/packages/#{rich.attribute}")

      assert html =~ "Source provenance"
      assert html =~ "binaryNativeCode"
    end

    test "does not display pname", %{conn: conn, rich: rich} do
      {:ok, _view, html} = live(conn, ~p"/packages/#{rich.attribute}")

      refute html =~ "rich-pname"
    end

    test "a lens span with only extended metadata is not treated as empty", %{
      conn: conn,
      cr2: cr2
    } do
      pkg =
        Tracker.Nixpkgs.Package
        |> Ash.Changeset.for_create(:create, %{attribute: "pkgshow-extonly"})
        |> Ash.create!()

      channel_meta =
        Channel.create!(%{
          name: Tracker.Ingestion.StepGraph.metadata_channel(),
          display_name: "Metadata Channel",
          status: :active,
          is_stable: false
        })

      cr_meta =
        Ash.create!(Tracker.Nixpkgs.ChannelRevision, %{
          channel_id: channel_meta.id,
          revision: "meta999fff888777",
          released_at: ~U[2026-03-18 10:00:00Z]
        })

      Tracker.Fixtures.apply_package_revision!(cr_meta, [
        {pkg, %{version: "1.0", description: "Fallback description"}}
      ])

      Tracker.Fixtures.apply_package_revision!(cr2, [
        {pkg, %{version: "1.0", main_program: "extbin"}}
      ])

      {:ok, _view, html} = live(conn, ~p"/packages/#{pkg.attribute}?lens_channel=nixos-24.11")

      assert html =~ "extbin"
      refute html =~ "Fallback description"
    end
  end

  test "updates when a revision result is recorded for the lens channel", %{
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

    Tracker.Fixtures.apply_package_revision!(cr3, [{package, "3.0.0"}])

    Tracker.Nixpkgs.ChannelRevision.record_result!(cr3, %{result: :success})

    html = render(view)
    assert html =~ "3.0.0"
  end

  test "displays package attribute as heading", %{conn: conn, package: package} do
    {:ok, _view, html} = live(conn, ~p"/packages/#{package.attribute}")

    assert html =~ "pkgshow-hello"
  end

  test "list sections use the shared section header", %{conn: conn, package: package} do
    {:ok, view, _html} = live(conn, ~p"/packages/#{package.attribute}")

    assert has_element?(view, ".section-header:has(#revision-filters) h2", "Revisions")
    assert has_element?(view, ".section-header:has(#revision-filters) .n", "1")
  end

  test "the feed link sits with the page actions, not in the revision filters", %{
    conn: conn,
    package: package
  } do
    {:ok, view, _html} = live(conn, ~p"/packages/#{package.attribute}")

    assert has_element?(view, "hgroup #feed-link")
    refute has_element?(view, "#revision-filters #feed-link")
  end

  test "loads with the lens set to all channels", %{conn: conn, package: package} do
    {:ok, _view, html} = live(conn, ~p"/packages/#{package.attribute}?lens_channel=all")

    assert html =~ "pkgshow-hello"
    assert html =~ "2.12.1"
    assert html =~ "2.13.0"
  end

  test "loads all revisions with the lens set to all channels", %{conn: conn, package: package} do
    {:ok, _view, html} =
      live(conn, ~p"/packages/#{package.attribute}?lens_channel=all&all_revisions=true")

    assert html =~ "pkgshow-hello"
    assert html =~ "2.12.1"
    assert html =~ "2.13.0"
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

  test "displays when each revision was released", %{conn: conn, package: package} do
    {:ok, _view, html} = live(conn, ~p"/packages/#{package.attribute}")

    assert html =~ "2026-03-01 10:00"
  end

  test "revisions are listed most recently released first", %{conn: conn, package: package} do
    {:ok, _view, html} = live(conn, ~p"/packages/#{package.attribute}")

    # Only nixos-unstable revision is shown (lens default)
    assert version_order(html) == ["2.12.1"]
  end

  test "revision order follows temporal order across months", %{
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

    Tracker.Fixtures.apply_package_revision!(cr_aug, [{pkg, "6.16.0"}])
    Tracker.Fixtures.apply_package_revision!(cr_sep, [{pkg, "6.17.0"}])

    {:ok, _view, html} = live(conn, ~p"/packages/crossmonth-pkg")

    # Sep 29 is newer than Aug 30, so 6.17.0 must appear first
    assert version_order(html) == ["6.17.0", "6.16.0"]
  end

  test "sort params no longer reorder the revisions", %{conn: conn, package: package} do
    {:ok, _view, html} =
      live(conn, ~p"/packages/#{package.attribute}?sort_by=version&sort_dir=asc")

    # Only one revision in the lens channel (nixos-unstable)
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
      package_family_id: family.id
    })
    |> Ash.create!()

    Tracker.Nixpkgs.Package
    |> Ash.Changeset.for_create(:bulk_upsert, %{
      attribute: "python312Packages.numpy",
      package_family_id: family.id
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
      option = Tracker.Fixtures.option!("services.hello.enable")

      Tracker.Fixtures.apply_option_packages!(cr1, [{option, package}])

      Tracker.Fixtures.apply_option_revision!(cr1, [
        {option, %{type: "boolean", description: "Whether to enable hello service."}}
      ])

      %{option: option}
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

    test "option links to options show page", %{conn: conn, package: package} do
      {:ok, _view, html} = live(conn, ~p"/packages/#{package.attribute}")

      assert html =~ ~s|/options/services.hello.enable|
    end

    test "drops an option that no longer links to the package (trk-387)", %{
      conn: conn,
      package: package,
      channel_unstable: channel_unstable
    } do
      later =
        Ash.create!(Tracker.Nixpkgs.ChannelRevision, %{
          channel_id: channel_unstable.id,
          revision: "abc123def456790",
          released_at: ~U[2026-03-20 10:00:00Z]
        })

      # The revision declares no links at all, closing the open one.
      Tracker.Fixtures.apply_option_packages!(later, [])

      {:ok, _view, html} = live(conn, ~p"/packages/#{package.attribute}")

      refute html =~ "NixOS Options"
      refute html =~ "services.hello.enable"
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

      Tracker.Fixtures.apply_package_revision!(cr3, [{package, "2.12.1"}])

      # Add a fourth unstable revision with a new version (real change)
      cr4 =
        Ash.create!(Tracker.Nixpkgs.ChannelRevision, %{
          channel_id: channel_unstable.id,
          revision: "chg333ddd444555",
          released_at: ~U[2026-03-20 10:00:00Z]
        })

      Tracker.Fixtures.apply_package_revision!(cr4, [{package, "2.14.0"}])

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

    test "revision filter form submits via GET for no-JS fallback", %{
      conn: conn,
      package: package
    } do
      {:ok, _view, html} = live(conn, ~p"/packages/#{package.attribute}")

      [form] =
        html
        |> Floki.parse_document!()
        |> Floki.find("form.revision-filters")

      assert Floki.attribute(form, "method") == ["get"]
      assert Floki.attribute(form, "action") == ["/packages/#{package.attribute}"]
    end

    test "filtering by version keeps the all_revisions toggle in the URL", %{
      conn: conn,
      package: package
    } do
      {:ok, view, _html} =
        live(conn, ~p"/packages/#{package.attribute}?all_revisions=true")

      view
      |> element("form.revision-filters")
      |> render_change(%{"version" => "2.12", "all_revisions" => "true"})

      url = assert_patch(view)
      assert url =~ "all_revisions=true"
      assert url =~ "version=2.12"
    end
  end

  describe "recent changes lens filtering" do
    setup %{package: package} do
      change_in =
        Tracker.Nixpkgs.Change
        |> Ash.Changeset.for_create(:bulk_upsert, %{
          number: 70001,
          title: "in-lens change",
          state: :merged,
          author: "alice"
        })
        |> Ash.create!()

      change_out =
        Tracker.Nixpkgs.Change
        |> Ash.Changeset.for_create(:bulk_upsert, %{
          number: 70002,
          title: "out-of-lens change",
          state: :merged,
          author: "bob"
        })
        |> Ash.create!()

      Tracker.Nixpkgs.ChangePackage
      |> Ash.Changeset.for_create(:load, %{
        change_id: change_in.id,
        package_id: package.id,
        type: :changed
      })
      |> Ash.create!()

      Tracker.Nixpkgs.ChangePackage
      |> Ash.Changeset.for_create(:load, %{
        change_id: change_out.id,
        package_id: package.id,
        type: :changed
      })
      |> Ash.create!()

      Tracker.Nixpkgs.ChangeBranch.create!(%{
        change_id: change_in.id,
        branch_name: "nixos-unstable"
      })

      Tracker.Nixpkgs.ChangeBranch.create!(%{
        change_id: change_out.id,
        branch_name: "nixos-24.11"
      })

      %{change_in: change_in, change_out: change_out}
    end

    test "default lens filters recent changes to the lens channel", %{
      conn: conn,
      package: package
    } do
      {:ok, _view, html} = live(conn, ~p"/packages/#{package.attribute}")

      assert html =~ "in-lens change"
      refute html =~ "out-of-lens change"
    end

    test "lens swap reloads recent changes for the new channel", %{
      conn: conn,
      package: package,
      channel_stable: channel_stable
    } do
      {:ok, view, _html} = live(conn, ~p"/packages/#{package.attribute}")

      send(view.pid, {:set_lens, channel_stable.name, ""})
      html = render(view)

      assert html =~ "out-of-lens change"
      refute html =~ "in-lens change"
    end
  end

  describe "lifecycle events lens filtering" do
    # The top-level setup leaves the package open in unstable (an "added"
    # boundary) and open in stable; here we close the stable span so stable
    # also shows a "removed" boundary.
    setup %{package: package, channel_stable: channel_stable} do
      cr_remove =
        Ash.create!(Tracker.Nixpkgs.ChannelRevision, %{
          channel_id: channel_stable.id,
          revision: "stableremove1234",
          released_at: ~U[2026-04-01 10:00:00Z]
        })

      Tracker.Fixtures.remove_package!(cr_remove, package)

      :ok
    end

    test "default lens filters lifecycle events to the lens channel", %{
      conn: conn,
      package: package
    } do
      {:ok, _view, html} = live(conn, ~p"/packages/#{package.attribute}")

      # Unstable: package is still present → only an "added" boundary.
      assert html =~ "Lifecycle Events"
      assert html =~ "added"
      refute html =~ "removed"
    end

    test "lens swap reloads lifecycle events for the new channel", %{
      conn: conn,
      package: package,
      channel_stable: channel_stable
    } do
      {:ok, view, _html} = live(conn, ~p"/packages/#{package.attribute}")

      send(view.pid, {:set_lens, channel_stable.name, ""})
      html = render(view)

      # Stable: the package was added then removed → a "removed" boundary.
      assert html =~ "removed"
    end
  end

  defp version_order(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("#revisions .row-label")
    |> Enum.map(&(&1 |> Floki.text() |> String.trim()))
  end
end

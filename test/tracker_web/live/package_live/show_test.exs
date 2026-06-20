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

    Tracker.Fixtures.apply_package_revision!(cr_aug, [{pkg, "6.16.0"}])
    Tracker.Fixtures.apply_package_revision!(cr_sep, [{pkg, "6.17.0"}])

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
    # P3 (trk-322): the linked-options section still reads the option-revision
    # model, which is removed until the options vertical lands.
    @describetag :skip
    setup %{package: package, cr1: cr1} do
      option =
        Tracker.Nixpkgs.Option
        |> Ash.Changeset.for_create(:bulk_upsert, %{
          name: "services.hello.enable"
        })
        |> Ash.create!()

      Tracker.Nixpkgs.OptionPackage.load!(%{
        option_id: option.id,
        package_id: package.id
      })

      Tracker.Nixpkgs.OptionRevision
      |> Ash.Changeset.for_create(:load, %{
        option_id: option.id,
        channel_revision_id: cr1.id,
        type: "boolean",
        description: "Whether to enable hello service."
      })
      |> Ash.create!()

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
    ~r/<td[^>]*>\s*(\d+\.\d+\.\d+)\s*<\/td>/
    |> Regex.scan(html)
    |> Enum.map(fn [_, version] -> version end)
  end
end

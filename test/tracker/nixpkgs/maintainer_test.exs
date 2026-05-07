defmodule Tracker.Nixpkgs.MaintainerTest do
  use Tracker.DataCase, async: true

  alias Tracker.Nixpkgs.{
    Channel,
    ChannelRevision,
    Maintainer,
    Package,
    PackageMaintainer,
    PackageRevision
  }

  describe "list/2 channel filtering" do
    setup do
      channel =
        Channel.create!(%{
          name: "nixos-unstable",
          display_name: "nixos-unstable",
          status: :active,
          is_stable: false
        })

      cr =
        ChannelRevision
        |> Ash.Changeset.for_create(:create, %{
          channel_id: channel.id,
          revision: "aaa1111",
          released_at: ~U[2025-01-01 00:00:00Z]
        })
        |> Ash.create!()

      maint_in =
        Maintainer
        |> Ash.Changeset.for_create(:bulk_upsert, %{github_id: 1001, github: "maint-in"})
        |> Ash.create!()

      maint_out =
        Maintainer
        |> Ash.Changeset.for_create(:bulk_upsert, %{github_id: 1002, github: "maint-out"})
        |> Ash.create!()

      pkg_in =
        Package.bulk_upsert_all([%{attribute: "maint-in-pkg"}])
        |> Map.fetch!("maint-in-pkg")
        |> then(&Ash.get!(Package, &1))

      pkg_out =
        Package.bulk_upsert_all([%{attribute: "maint-out-pkg"}])
        |> Map.fetch!("maint-out-pkg")
        |> then(&Ash.get!(Package, &1))

      # Only pkg_in has a revision in the channel
      PackageRevision
      |> Ash.Changeset.for_create(:load, %{
        version: "1.0",
        package_id: pkg_in.id,
        channel_revision_id: cr.id
      })
      |> Ash.create!()

      # Link maintainers to their respective packages
      PackageMaintainer.load!(%{package_id: pkg_in.id, maintainer_id: maint_in.id})
      PackageMaintainer.load!(%{package_id: pkg_out.id, maintainer_id: maint_out.id})

      %{channel: channel, maint_in: maint_in, maint_out: maint_out}
    end

    test "without channel_id returns all maintainers", %{maint_in: maint_in, maint_out: maint_out} do
      page = Maintainer.list!(nil, nil, page: [count: true])

      githubs = Enum.map(page.results, & &1.github)
      assert maint_in.github in githubs
      assert maint_out.github in githubs
    end

    test "with channel_id returns only maintainers with packages in that channel", %{
      channel: channel,
      maint_in: maint_in,
      maint_out: maint_out
    } do
      page = Maintainer.list!(nil, channel.id, page: [count: true])

      githubs = Enum.map(page.results, & &1.github)
      assert maint_in.github in githubs
      refute maint_out.github in githubs
    end
  end
end

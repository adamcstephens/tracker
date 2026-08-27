defmodule Tracker.Nixpkgs.ChannelTest do
  use Tracker.DataCase, async: true

  alias Tracker.Nixpkgs.Channel

  describe "create/1" do
    test "creates a channel with all attributes" do
      {:ok, channel} =
        Channel.create(%{
          name: "nixos-chantest",
          display_name: "NixOS Unstable",
          status: :active,
          is_stable: false,
          options_source: "nixos"
        })

      assert channel.name == "nixos-chantest"
      assert channel.display_name == "NixOS Unstable"
      assert channel.status == :active
      assert channel.is_stable == false
      assert channel.options_source == "nixos"
    end

    test "enforces required attributes" do
      assert {:error, _} = Channel.create(%{})
    end

    test "upserts on name" do
      {:ok, c1} =
        Channel.create(%{
          name: "nixos-chantest",
          display_name: "NixOS Unstable",
          status: :active,
          is_stable: false
        })

      {:ok, c2} =
        Channel.create(%{
          name: "nixos-chantest",
          display_name: "NixOS Unstable (updated)",
          status: :retired,
          is_stable: false
        })

      assert c1.id == c2.id
      assert c2.display_name == "NixOS Unstable (updated)"
      assert c2.status == :retired
    end
  end

  describe "status values" do
    test "supports active, retired, and pre_release" do
      for status <- [:active, :retired, :pre_release] do
        {:ok, channel} =
          Channel.create(%{
            name: "test-#{status}",
            display_name: "Test",
            status: status,
            is_stable: false
          })

        assert channel.status == status
      end
    end
  end

  describe "active/0" do
    test "returns active and pre_release channels but excludes retired" do
      Channel.create!(%{
        name: "nixos-chantest",
        display_name: "NixOS Unstable",
        status: :active,
        is_stable: false
      })

      Channel.create!(%{
        name: "nixos-26.51",
        display_name: "NixOS 26.05",
        status: :pre_release,
        is_stable: true
      })

      Channel.create!(%{
        name: "nixos-24.51",
        display_name: "NixOS 24.05",
        status: :retired,
        is_stable: true
      })

      names = Channel.active!() |> Enum.map(& &1.name)
      assert "nixos-chantest" in names
      assert "nixos-26.51" in names
      refute "nixos-24.51" in names
    end
  end

  describe "by_name/1" do
    test "finds a channel by name" do
      Channel.create!(%{
        name: "nixos-chantest",
        display_name: "NixOS Unstable",
        status: :active,
        is_stable: false
      })

      {:ok, channel} = Channel.by_name("nixos-chantest")
      assert channel.name == "nixos-chantest"
    end

    test "returns error for unknown channel" do
      assert {:error, _} = Channel.by_name("nonexistent")
    end
  end

  describe "nixos_channels/0" do
    test "returns only live nixos-* channels sorted by name" do
      Channel.create!(%{
        name: "nixos-chantest-old",
        display_name: "NixOS Retired",
        status: :retired,
        is_stable: true
      })

      Channel.create!(%{
        name: "nixpkgs-chantest",
        display_name: "Nixpkgs Unstable",
        status: :active,
        is_stable: false
      })

      Channel.create!(%{
        name: "nixos-chantest",
        display_name: "NixOS Unstable",
        status: :active,
        is_stable: false
      })

      Channel.create!(%{
        name: "nixos-25.51",
        display_name: "NixOS 25.11",
        status: :active,
        is_stable: true
      })

      channels = Channel.nixos_channels!()
      names = Enum.map(channels, & &1.name)

      assert names == ["nixos-25.51", "nixos-chantest"]
    end
  end

  describe "default_stable/0" do
    test "returns the highest-versioned active stable channel" do
      s = System.unique_integer([:positive])

      Channel.create!(%{
        name: "nixos-24.#{s}",
        display_name: "NixOS 24.#{s}",
        status: :active,
        is_stable: true
      })

      Channel.create!(%{
        name: "nixos-25.#{s}",
        display_name: "NixOS 25.#{s}",
        status: :active,
        is_stable: true
      })

      {:ok, channel} = Channel.default_stable()
      assert channel.name == "nixos-25.#{s}"
    end

    test "ignores retired and pre_release channels" do
      s = System.unique_integer([:positive])

      Channel.create!(%{
        name: "nixos-25.#{s}",
        display_name: "NixOS 25.#{s}",
        status: :retired,
        is_stable: true
      })

      Channel.create!(%{
        name: "nixos-24.#{s}",
        display_name: "NixOS 24.#{s}",
        status: :active,
        is_stable: true
      })

      Channel.create!(%{
        name: "nixos-26.#{s}",
        display_name: "NixOS 26.#{s}",
        status: :pre_release,
        is_stable: true
      })

      {:ok, channel} = Channel.default_stable()
      assert channel.name == "nixos-24.#{s}"
    end

    test "ignores non-stable channels" do
      s = System.unique_integer([:positive])

      Channel.create!(%{
        name: "nixos-unstable-#{s}",
        display_name: "NixOS Unstable #{s}",
        status: :active,
        is_stable: false
      })

      assert {:error, _} = Channel.default_stable()
    end

    test "returns error when no stable active channels exist" do
      assert {:error, _} = Channel.default_stable()
    end
  end

  describe "update_hydra_status/2" do
    setup do
      channel =
        Channel.create!(%{
          name: "nixos-unstable-#{System.unique_integer([:positive])}",
          display_name: "NixOS Unstable",
          status: :active,
          is_stable: false
        })

      %{channel: channel}
    end

    test "stores hydra fields and stamps hydra_checked_at", %{channel: channel} do
      {:ok, updated} =
        Channel.update_hydra_status(channel, %{
          hydra_build_failed?: true,
          hydra_project: "nixos",
          hydra_jobset: "unstable",
          hydra_exported_job: "tested"
        })

      assert updated.hydra_build_failed? == true
      assert updated.hydra_project == "nixos"
      assert updated.hydra_jobset == "unstable"
      assert updated.hydra_exported_job == "tested"
      assert %DateTime{} = updated.hydra_checked_at
    end

    test "overwrites previously stored values", %{channel: channel} do
      {:ok, _} =
        Channel.update_hydra_status(channel, %{
          hydra_build_failed?: true,
          hydra_project: "nixos",
          hydra_jobset: "unstable",
          hydra_exported_job: "tested"
        })

      {:ok, updated} =
        Channel.update_hydra_status(channel, %{
          hydra_build_failed?: false,
          hydra_project: "nixos",
          hydra_jobset: "unstable",
          hydra_exported_job: "tested"
        })

      assert updated.hydra_build_failed? == false
    end
  end

  describe "build_problem? calculation" do
    test "is true when the latest hydra job failed and channel is active" do
      channel =
        Channel.create!(%{
          name: "nixos-unstable-#{System.unique_integer([:positive])}",
          display_name: "NixOS Unstable",
          status: :active,
          is_stable: false
        })

      {:ok, _} =
        Channel.update_hydra_status(channel, %{
          hydra_build_failed?: true,
          hydra_project: "nixos",
          hydra_jobset: "unstable",
          hydra_exported_job: "tested"
        })

      {:ok, loaded} =
        Channel.by_name(channel.name, load: [:build_problem?])

      assert loaded.build_problem? == true
    end

    test "is false when the latest hydra job succeeded" do
      channel =
        Channel.create!(%{
          name: "nixos-unstable-#{System.unique_integer([:positive])}",
          display_name: "NixOS Unstable",
          status: :active,
          is_stable: false
        })

      {:ok, _} =
        Channel.update_hydra_status(channel, %{
          hydra_build_failed?: false,
          hydra_project: "nixos",
          hydra_jobset: "unstable",
          hydra_exported_job: "tested"
        })

      {:ok, loaded} =
        Channel.by_name(channel.name, load: [:build_problem?])

      assert loaded.build_problem? == false
    end

    test "is suppressed for retired channels even when hydra reports failure" do
      channel =
        Channel.create!(%{
          name: "nixos-old-#{System.unique_integer([:positive])}",
          display_name: "Old",
          status: :retired,
          is_stable: true
        })

      {:ok, _} =
        Channel.update_hydra_status(channel, %{
          hydra_build_failed?: true,
          hydra_project: "nixos",
          hydra_jobset: "release-old",
          hydra_exported_job: "tested"
        })

      {:ok, loaded} =
        Channel.by_name(channel.name, load: [:build_problem?])

      assert loaded.build_problem? == false
    end

    test "is false when hydra status hasn't been fetched yet" do
      channel =
        Channel.create!(%{
          name: "nixos-fresh-#{System.unique_integer([:positive])}",
          display_name: "Fresh",
          status: :active,
          is_stable: false
        })

      {:ok, loaded} = Channel.by_name(channel.name, load: [:build_problem?])
      assert loaded.build_problem? == false
    end
  end

  describe "revision aggregates" do
    setup do
      channel =
        Channel.create!(%{
          name: "nixos-aggregate-#{System.unique_integer([:positive])}",
          display_name: "Aggregates",
          status: :active,
          is_stable: false
        })

      %{channel: channel}
    end

    test "revision_count and latest_release are zero and nil without revisions", %{
      channel: channel
    } do
      {:ok, loaded} = Channel.by_name(channel.name, load: [:revision_count, :latest_release])

      assert loaded.revision_count == 0
      assert loaded.latest_release == nil
    end

    test "revision_count counts the channel's revisions", %{channel: channel} do
      other =
        Channel.create!(%{
          name: "nixos-other-#{System.unique_integer([:positive])}",
          display_name: "Other",
          status: :active,
          is_stable: false
        })

      for {ch, at} <- [
            {channel, ~U[2026-03-01 10:00:00Z]},
            {channel, ~U[2026-03-15 10:00:00Z]},
            {other, ~U[2026-03-20 10:00:00Z]}
          ] do
        Ash.create!(Tracker.Nixpkgs.ChannelRevision, %{
          channel_id: ch.id,
          revision: "rev#{System.unique_integer([:positive])}",
          released_at: at
        })
      end

      {:ok, loaded} = Channel.by_name(channel.name, load: [:revision_count])
      assert loaded.revision_count == 2
    end

    test "latest_release is the newest released_at", %{channel: channel} do
      for at <- [~U[2026-03-15 10:00:00Z], ~U[2026-03-01 10:00:00Z], ~U[2026-03-10 10:00:00Z]] do
        Ash.create!(Tracker.Nixpkgs.ChannelRevision, %{
          channel_id: channel.id,
          revision: "rev#{System.unique_integer([:positive])}",
          released_at: at
        })
      end

      {:ok, loaded} = Channel.by_name(channel.name, load: [:latest_release])
      assert loaded.latest_release == ~U[2026-03-15 10:00:00Z]
    end
  end

  describe "hydra_job_links/3" do
    test "builds a link per hydra-built platform on a nixos jobset" do
      channel = %Channel{hydra_project: "nixos", hydra_jobset: "unstable"}

      assert Channel.hydra_job_links(channel, "hello", [
               "x86_64-linux",
               "aarch64-linux",
               "riscv64-linux"
             ]) == [
               {"x86_64-linux",
                "https://hydra.nixos.org/job/nixos/unstable/nixpkgs.hello.x86_64-linux"},
               {"aarch64-linux",
                "https://hydra.nixos.org/job/nixos/unstable/nixpkgs.hello.aarch64-linux"}
             ]
    end

    test "omits darwin on a nixos jobset" do
      channel = %Channel{hydra_project: "nixos", hydra_jobset: "release-26.05"}

      assert Channel.hydra_job_links(channel, "hello", ["aarch64-darwin"]) == []
    end

    test "includes darwin and drops the nixpkgs prefix on a nixpkgs jobset" do
      channel = %Channel{hydra_project: "nixpkgs", hydra_jobset: "unstable"}

      assert Channel.hydra_job_links(channel, "hello", ["aarch64-darwin", "x86_64-linux"]) == [
               {"x86_64-linux",
                "https://hydra.nixos.org/job/nixpkgs/unstable/hello.x86_64-linux"},
               {"aarch64-darwin",
                "https://hydra.nixos.org/job/nixpkgs/unstable/hello.aarch64-darwin"}
             ]
    end

    test "is empty without a jobset" do
      assert Channel.hydra_job_links(%Channel{}, "hello", ["x86_64-linux"]) == []
    end

    test "is empty without platforms" do
      channel = %Channel{hydra_project: "nixos", hydra_jobset: "unstable"}

      assert Channel.hydra_job_links(channel, "hello", nil) == []
    end
  end
end

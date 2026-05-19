defmodule Tracker.Nixpkgs.ChannelTest do
  use Tracker.DataCase, async: true

  alias Tracker.Nixpkgs.Channel

  describe "create/1" do
    test "creates a channel with all attributes" do
      {:ok, channel} =
        Channel.create(%{
          name: "nixos-unstable",
          display_name: "NixOS Unstable",
          status: :active,
          is_stable: false,
          options_source: "nixos"
        })

      assert channel.name == "nixos-unstable"
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
          name: "nixos-unstable",
          display_name: "NixOS Unstable",
          status: :active,
          is_stable: false
        })

      {:ok, c2} =
        Channel.create(%{
          name: "nixos-unstable",
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
    test "returns only active channels" do
      Channel.create!(%{
        name: "nixos-unstable",
        display_name: "NixOS Unstable",
        status: :active,
        is_stable: false
      })

      Channel.create!(%{
        name: "nixos-24.05",
        display_name: "NixOS 24.05",
        status: :retired,
        is_stable: true
      })

      active = Channel.active!()
      assert length(active) == 1
      assert hd(active).name == "nixos-unstable"
    end
  end

  describe "by_name/1" do
    test "finds a channel by name" do
      Channel.create!(%{
        name: "nixos-unstable",
        display_name: "NixOS Unstable",
        status: :active,
        is_stable: false
      })

      {:ok, channel} = Channel.by_name("nixos-unstable")
      assert channel.name == "nixos-unstable"
    end

    test "returns error for unknown channel" do
      assert {:error, _} = Channel.by_name("nonexistent")
    end
  end

  describe "nixos_channels/0" do
    test "returns only nixos-* channels sorted by name" do
      Channel.create!(%{
        name: "nixpkgs-unstable",
        display_name: "Nixpkgs Unstable",
        status: :active,
        is_stable: false
      })

      Channel.create!(%{
        name: "nixos-unstable",
        display_name: "NixOS Unstable",
        status: :active,
        is_stable: false
      })

      Channel.create!(%{
        name: "nixos-25.11",
        display_name: "NixOS 25.11",
        status: :active,
        is_stable: true
      })

      channels = Channel.nixos_channels!()
      names = Enum.map(channels, & &1.name)

      assert names == ["nixos-25.11", "nixos-unstable"]
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

  # seed!/0 tests live in channel_seed_test.exs (async: false)
  # because seed! uses hardcoded channel names that conflict with
  # other async tests doing upserts on the same names.
end

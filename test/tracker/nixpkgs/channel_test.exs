defmodule Tracker.Nixpkgs.ChannelTest do
  use Tracker.DataCase, async: true

  alias Tracker.Nixpkgs.Channel

  describe "create/1" do
    test "creates a channel with all attributes" do
      {:ok, channel} =
        Channel.create(%{
          name: "nixos-unstable",
          display_name: "NixOS Unstable",
          branch: "nixos-unstable",
          status: :active,
          is_stable: false,
          options_source: "nixos"
        })

      assert channel.name == "nixos-unstable"
      assert channel.display_name == "NixOS Unstable"
      assert channel.branch == "nixos-unstable"
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
          branch: "nixos-unstable",
          status: :active,
          is_stable: false
        })

      {:ok, c2} =
        Channel.create(%{
          name: "nixos-unstable",
          display_name: "NixOS Unstable (updated)",
          branch: "nixos-unstable",
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
            branch: "test",
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
        branch: "nixos-unstable",
        status: :active,
        is_stable: false
      })

      Channel.create!(%{
        name: "nixos-24.05",
        display_name: "NixOS 24.05",
        branch: "release-24.05",
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
        branch: "nixos-unstable",
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
        branch: "nixpkgs-unstable",
        status: :active,
        is_stable: false
      })

      Channel.create!(%{
        name: "nixos-unstable",
        display_name: "NixOS Unstable",
        branch: "nixos-unstable",
        status: :active,
        is_stable: false
      })

      Channel.create!(%{
        name: "nixos-25.11",
        display_name: "NixOS 25.11",
        branch: "release-25.11",
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
        branch: "release-24.#{s}",
        status: :active,
        is_stable: true
      })

      Channel.create!(%{
        name: "nixos-25.#{s}",
        display_name: "NixOS 25.#{s}",
        branch: "release-25.#{s}",
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
        branch: "release-25.#{s}",
        status: :retired,
        is_stable: true
      })

      Channel.create!(%{
        name: "nixos-24.#{s}",
        display_name: "NixOS 24.#{s}",
        branch: "release-24.#{s}",
        status: :active,
        is_stable: true
      })

      Channel.create!(%{
        name: "nixos-26.#{s}",
        display_name: "NixOS 26.#{s}",
        branch: "release-26.#{s}",
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
        branch: "nixos-unstable-#{s}",
        status: :active,
        is_stable: false
      })

      assert {:error, _} = Channel.default_stable()
    end

    test "returns error when no stable active channels exist" do
      assert {:error, _} = Channel.default_stable()
    end
  end

  describe "seed!/0" do
    @test_channels ["nixos-25.11", "nixos-unstable", "nixos-unstable-small", "nixpkgs-unstable"]

    setup do
      previous = Application.get_env(:tracker, :channels)
      Application.put_env(:tracker, :channels, @test_channels)
      on_exit(fn -> Application.put_env(:tracker, :channels, previous) end)
    end

    test "creates channels from application config" do
      Channel.seed!()

      channels = Channel.read!()

      assert length(channels) == length(@test_channels)
      assert Enum.all?(@test_channels, fn name -> Enum.any?(channels, &(&1.name == name)) end)
    end

    test "marks version-numbered channels as stable" do
      Channel.seed!()

      {:ok, stable} = Channel.by_name("nixos-25.11")
      {:ok, unstable} = Channel.by_name("nixos-unstable")

      assert stable.is_stable == true
      assert unstable.is_stable == false
    end

    test "generates display names from channel names" do
      Channel.seed!()

      {:ok, ch} = Channel.by_name("nixos-unstable-small")
      assert ch.display_name == "nixos-unstable-small"
    end

    test "is idempotent" do
      Channel.seed!()
      Channel.seed!()

      assert length(Channel.read!()) == length(@test_channels)
    end
  end
end

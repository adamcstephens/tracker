defmodule Tracker.Nixpkgs.ChannelSeedTest do
  use Tracker.DataCase, async: false

  alias Tracker.Nixpkgs.Channel

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

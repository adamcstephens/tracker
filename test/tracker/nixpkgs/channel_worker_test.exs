defmodule Tracker.Nixpkgs.ChannelWorkerTest do
  use Tracker.DataCase, async: true

  alias Tracker.Nixpkgs.ChannelWorker

  describe "write_to_database/1" do
    test "accepts version as integer" do
      data = %{
        "packages" => %{},
        "version" => 2,
        "revision" => "abc123",
        "channel" => "nixos-unstable"
      }

      assert :success = ChannelWorker.write_to_database(data)
    end

    test "accepts version as string" do
      data = %{
        "packages" => %{},
        "version" => "2",
        "revision" => "def456",
        "channel" => "nixos-unstable"
      }

      assert :success = ChannelWorker.write_to_database(data)
    end

    test "rejects unsupported version" do
      data = %{
        "packages" => %{},
        "version" => 3,
        "revision" => "ghi789",
        "channel" => "nixos-unstable"
      }

      assert {:error, :unsupported_version} = ChannelWorker.write_to_database(data)
    end
  end
end

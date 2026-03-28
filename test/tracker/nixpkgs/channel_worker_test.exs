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

    test "loads packages and revisions" do
      data = %{
        "packages" => %{
          "hello" => %{"version" => "2.12.1"},
          "curl" => %{"version" => "8.7.1"}
        },
        "version" => 2,
        "revision" => "load123",
        "channel" => "nixos-unstable"
      }

      assert :success = ChannelWorker.write_to_database(data)

      assert %{rows: [[2]]} =
               Ecto.Adapters.SQL.query!(Tracker.Repo, "SELECT count(*) FROM packages")

      assert %{rows: [[2]]} =
               Ecto.Adapters.SQL.query!(Tracker.Repo, "SELECT count(*) FROM package_revisions")
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

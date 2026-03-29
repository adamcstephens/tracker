defmodule Tracker.Nixpkgs.ChannelWorkerTest do
  use Tracker.DataCase, async: true

  alias Tracker.Nixpkgs.ChannelWorker

  describe "write_to_database/1" do
    test "stores released_at on channel revision" do
      data = %{
        "packages" => %{},
        "version" => 2,
        "revision" => "rel123",
        "channel" => "nixos-unstable",
        "released_at" => "2026-03-15T10:00:00.000Z"
      }

      assert :success = ChannelWorker.write_to_database(data)

      {:ok, cr} = Tracker.Nixpkgs.ChannelRevision.find("nixos-unstable", "rel123")
      assert cr.released_at == ~U[2026-03-15 10:00:00Z]
    end

    test "accepts version as integer" do
      data = %{
        "packages" => %{},
        "version" => 2,
        "revision" => "abc123",
        "channel" => "nixos-unstable",
        "released_at" => "2026-03-01T10:00:00.000Z"
      }

      assert :success = ChannelWorker.write_to_database(data)
    end

    test "accepts version as string" do
      data = %{
        "packages" => %{},
        "version" => "2",
        "revision" => "def456",
        "channel" => "nixos-unstable",
        "released_at" => "2026-03-01T10:00:00.000Z"
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
        "channel" => "nixos-unstable",
        "released_at" => "2026-03-01T10:00:00.000Z"
      }

      assert :success = ChannelWorker.write_to_database(data)

      assert %{rows: [[2]]} =
               Ecto.Adapters.SQL.query!(Tracker.Repo, "SELECT count(*) FROM packages")

      assert %{rows: [[2]]} =
               Ecto.Adapters.SQL.query!(Tracker.Repo, "SELECT count(*) FROM package_revisions")
    end

    @tag :capture_log
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

  describe "parse_releases/1" do
    test "parses contents into release maps sorted by date descending" do
      contents = [
        %{
          "Key" => "nixos/25.11-small/nixos-25.11.1036.d355f89e0014",
          "LastModified" => "2025-12-05T19:58:15.000Z"
        },
        %{
          "Key" => "nixos/25.11-small/nixos-25.11.1353.1acf2f172ef3",
          "LastModified" => "2025-12-10T07:07:35.000Z"
        },
        %{
          "Key" => "nixos/25.11-small/nixos-25.11.1119.60a511057b11",
          "LastModified" => "2025-12-06T21:54:24.000Z"
        }
      ]

      result = ChannelWorker.parse_releases(contents)

      assert [first, second, third] = result
      assert first.short_hash == "1acf2f172ef3"
      assert first.released_at == "2025-12-10T07:07:35.000Z"

      assert first.base_url ==
               "https://releases.nixos.org/nixos/25.11-small/nixos-25.11.1353.1acf2f172ef3"

      assert second.short_hash == "60a511057b11"
      assert third.short_hash == "d355f89e0014"
    end

    test "handles single entry (map instead of list)" do
      entry = %{
        "Key" => "nixos/25.11-small/nixos-25.11.1036.d355f89e0014",
        "LastModified" => "2025-12-05T19:58:15.000Z"
      }

      assert [release] = ChannelWorker.parse_releases(entry)
      assert release.short_hash == "d355f89e0014"
      assert release.released_at == "2025-12-05T19:58:15.000Z"
    end

    test "handles beta releases" do
      contents = [
        %{
          "Key" => "nixos/25.11-small/nixos-25.11beta5.a320ce8e6e2c",
          "LastModified" => "2025-11-01T10:00:00.000Z"
        }
      ]

      assert [release] = ChannelWorker.parse_releases(contents)
      assert release.short_hash == "a320ce8e6e2c"

      assert release.base_url ==
               "https://releases.nixos.org/nixos/25.11-small/nixos-25.11beta5.a320ce8e6e2c"
    end
  end

  describe "filter_existing_releases/2" do
    test "filters out releases whose short hash matches an existing revision" do
      # Create an existing channel revision
      Tracker.Nixpkgs.ChannelRevision
      |> Ash.Changeset.for_create(:create, %{
        channel: "nixos-25.11-small",
        revision: "d355f89e0014e51c9511298089d7ab55fd6f7056",
        released_at: ~U[2025-12-05 19:58:15Z]
      })
      |> Ash.create!()

      releases = [
        %{
          build_number: 1353,
          short_hash: "1acf2f172ef3",
          base_url: "https://releases.nixos.org/nixos/25.11-small/nixos-25.11.1353.1acf2f172ef3"
        },
        %{
          build_number: 1036,
          short_hash: "d355f89e0014",
          base_url: "https://releases.nixos.org/nixos/25.11-small/nixos-25.11.1036.d355f89e0014"
        }
      ]

      result = ChannelWorker.filter_existing_releases(releases, "nixos-25.11-small")

      assert [remaining] = result
      assert remaining.short_hash == "1acf2f172ef3"
    end

    test "keeps all releases when none exist in DB" do
      releases = [
        %{build_number: 1353, short_hash: "1acf2f172ef3", base_url: "url1"},
        %{build_number: 1036, short_hash: "d355f89e0014", base_url: "url2"}
      ]

      result = ChannelWorker.filter_existing_releases(releases, "nixos-25.11-small")

      assert length(result) == 2
    end
  end
end

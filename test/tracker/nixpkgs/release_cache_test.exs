defmodule Tracker.Nixpkgs.ReleaseCacheTest do
  use ExUnit.Case, async: true

  alias Tracker.Nixpkgs.ReleaseCache
  alias Tracker.Nixpkgs.ReleaseCache.Release

  describe "parse_releases/1" do
    test "parses S3 contents into Release structs sorted by released_at desc" do
      contents = [
        %{
          "Key" => "nixos/unstable/nixos-25.05pre20250301.abc1234",
          "LastModified" => "2025-03-01T10:00:00Z"
        },
        %{
          "Key" => "nixos/unstable/nixos-25.05pre20250303.def5678",
          "LastModified" => "2025-03-03T10:00:00Z"
        },
        %{
          "Key" => "nixos/unstable/nixos-25.05pre20250302.ghi9012",
          "LastModified" => "2025-03-02T10:00:00Z"
        }
      ]

      result = ReleaseCache.parse_releases(contents)

      assert [
               %Release{short_hash: "def5678", released_at: "2025-03-03T10:00:00Z"},
               %Release{short_hash: "ghi9012", released_at: "2025-03-02T10:00:00Z"},
               %Release{short_hash: "abc1234", released_at: "2025-03-01T10:00:00Z"}
             ] = result

      assert Enum.all?(result, fn r ->
               String.starts_with?(r.base_url, "https://releases.nixos.org/")
             end)
    end

    test "handles single entry wrapped in list" do
      contents = %{
        "Key" => "nixos/unstable/nixos-25.05pre20250301.abc1234",
        "LastModified" => "2025-03-01T10:00:00Z"
      }

      result = ReleaseCache.parse_releases(contents)
      assert [%Release{short_hash: "abc1234"}] = result
    end
  end

  describe "channel_to_s3_prefix/1" do
    test "maps nixos channels" do
      assert ReleaseCache.channel_to_s3_prefix("nixos-unstable") == "nixos/unstable/"
      assert ReleaseCache.channel_to_s3_prefix("nixos-24.11-small") == "nixos/24.11-small/"
    end

    test "maps nixpkgs channels" do
      assert ReleaseCache.channel_to_s3_prefix("nixpkgs-unstable") == "nixpkgs/unstable/"
    end

    test "passes through unknown channels" do
      assert ReleaseCache.channel_to_s3_prefix("other") == "other/"
    end
  end

  describe "GenServer" do
    setup do
      pid = start_supervised!({ReleaseCache, name: nil})
      %{pid: pid}
    end

    test "put_releases and get_releases", %{pid: pid} do
      releases = [
        %Release{
          short_hash: "abc1234",
          base_url: "https://example.com/abc",
          released_at: "2025-03-02T10:00:00Z"
        },
        %Release{
          short_hash: "def5678",
          base_url: "https://example.com/def",
          released_at: "2025-03-01T10:00:00Z"
        }
      ]

      ReleaseCache.put_releases(pid, "nixos-unstable", releases)
      assert ReleaseCache.get_releases(pid, "nixos-unstable") == releases
    end

    test "find_previous_release returns the chronologically previous release", %{pid: pid} do
      releases = [
        %Release{
          short_hash: "ccc",
          base_url: "https://example.com/c",
          released_at: "2025-03-03T10:00:00Z"
        },
        %Release{
          short_hash: "bbb",
          base_url: "https://example.com/b",
          released_at: "2025-03-02T10:00:00Z"
        },
        %Release{
          short_hash: "aaa",
          base_url: "https://example.com/a",
          released_at: "2025-03-01T10:00:00Z"
        }
      ]

      ReleaseCache.put_releases(pid, "nixos-unstable", releases)

      # Previous of newest (ccc) is bbb
      assert %Release{short_hash: "bbb"} =
               ReleaseCache.find_previous_release(pid, "nixos-unstable", "ccc")

      # Previous of middle (bbb) is aaa
      assert %Release{short_hash: "aaa"} =
               ReleaseCache.find_previous_release(pid, "nixos-unstable", "bbb")
    end

    test "find_previous_release returns nil for the oldest release", %{pid: pid} do
      releases = [
        %Release{
          short_hash: "bbb",
          base_url: "https://example.com/b",
          released_at: "2025-03-02T10:00:00Z"
        },
        %Release{
          short_hash: "aaa",
          base_url: "https://example.com/a",
          released_at: "2025-03-01T10:00:00Z"
        }
      ]

      ReleaseCache.put_releases(pid, "nixos-unstable", releases)
      assert ReleaseCache.find_previous_release(pid, "nixos-unstable", "aaa") == nil
    end

    test "find_previous_release returns nil for unknown short_hash", %{pid: pid} do
      releases = [
        %Release{
          short_hash: "aaa",
          base_url: "https://example.com/a",
          released_at: "2025-03-01T10:00:00Z"
        }
      ]

      ReleaseCache.put_releases(pid, "nixos-unstable", releases)
      assert ReleaseCache.find_previous_release(pid, "nixos-unstable", "zzz") == nil
    end

    test "find_previous_release returns nil for unknown channel", %{pid: pid} do
      assert ReleaseCache.find_previous_release(pid, "nonexistent", "aaa") == nil
    end
  end
end

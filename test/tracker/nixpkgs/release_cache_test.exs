defmodule Tracker.Nixpkgs.ReleaseCacheTest do
  use ExUnit.Case, async: true

  alias Tracker.Nixpkgs.ReleaseCache
  alias Tracker.Nixpkgs.ReleaseCache.Release

  describe "GenServer" do
    setup do
      pid = start_supervised!({ReleaseCache, name: nil})
      %{pid: pid}
    end

    test "put_releases and get_releases", %{pid: pid} do
      releases = [
        %Release{
          base_url: "https://example.com/abc",
          released_at: ~U[2025-03-02 10:00:00Z],
          revision: "abc1234" <> String.duplicate("0", 33)
        },
        %Release{
          base_url: "https://example.com/def",
          released_at: ~U[2025-03-01 10:00:00Z],
          revision: "def5678" <> String.duplicate("0", 33)
        }
      ]

      ReleaseCache.put_releases(pid, "nixos-unstable", releases)
      assert ReleaseCache.get_releases(pid, "nixos-unstable") == releases
    end

    test "find_previous_release returns the chronologically previous release", %{pid: pid} do
      releases = [
        %Release{
          base_url: "https://example.com/c",
          released_at: ~U[2025-03-03 10:00:00Z],
          revision: "ccc" <> String.duplicate("0", 37)
        },
        %Release{
          base_url: "https://example.com/b",
          released_at: ~U[2025-03-02 10:00:00Z],
          revision: "bbb" <> String.duplicate("0", 37)
        },
        %Release{
          base_url: "https://example.com/a",
          released_at: ~U[2025-03-01 10:00:00Z],
          revision: "aaa" <> String.duplicate("0", 37)
        }
      ]

      ReleaseCache.put_releases(pid, "nixos-unstable", releases)

      ccc_rev = "ccc" <> String.duplicate("0", 37)
      bbb_rev = "bbb" <> String.duplicate("0", 37)
      aaa_rev = "aaa" <> String.duplicate("0", 37)

      # Previous of newest (ccc) is bbb
      assert %Release{revision: ^bbb_rev} =
               ReleaseCache.find_previous_release(pid, "nixos-unstable", ccc_rev)

      # Previous of middle (bbb) is aaa
      assert %Release{revision: ^aaa_rev} =
               ReleaseCache.find_previous_release(pid, "nixos-unstable", bbb_rev)
    end

    test "find_previous_release returns nil for the oldest release", %{pid: pid} do
      bbb_rev = "bbb" <> String.duplicate("0", 37)
      aaa_rev = "aaa" <> String.duplicate("0", 37)

      releases = [
        %Release{
          base_url: "https://example.com/b",
          released_at: ~U[2025-03-02 10:00:00Z],
          revision: bbb_rev
        },
        %Release{
          base_url: "https://example.com/a",
          released_at: ~U[2025-03-01 10:00:00Z],
          revision: aaa_rev
        }
      ]

      ReleaseCache.put_releases(pid, "nixos-unstable", releases)
      assert ReleaseCache.find_previous_release(pid, "nixos-unstable", aaa_rev) == nil
    end

    test "find_previous_release returns nil for unknown revision", %{pid: pid} do
      releases = [
        %Release{
          base_url: "https://example.com/a",
          released_at: ~U[2025-03-01 10:00:00Z],
          revision: "aaa" <> String.duplicate("0", 37)
        }
      ]

      ReleaseCache.put_releases(pid, "nixos-unstable", releases)

      assert ReleaseCache.find_previous_release(
               pid,
               "nixos-unstable",
               "zzz" <> String.duplicate("0", 37)
             ) == nil
    end

    test "find_previous_release returns nil for unknown channel", %{pid: pid} do
      assert ReleaseCache.find_previous_release(
               pid,
               "nonexistent",
               "aaa" <> String.duplicate("0", 37)
             ) == nil
    end

    test "find_by_base_url returns matching release", %{pid: pid} do
      abc_rev = "abc1234" <> String.duplicate("0", 33)

      releases = [
        %Release{
          base_url: "https://releases.nixos.org/nixos/unstable/abc1234",
          released_at: ~U[2025-03-02 10:00:00Z],
          revision: abc_rev
        },
        %Release{
          base_url: "https://releases.nixos.org/nixos/unstable/def5678",
          released_at: ~U[2025-03-01 10:00:00Z],
          revision: "def5678" <> String.duplicate("0", 33)
        }
      ]

      ReleaseCache.put_releases(pid, "nixos-unstable", releases)

      assert %Release{revision: ^abc_rev} =
               ReleaseCache.find_by_base_url(
                 pid,
                 "nixos-unstable",
                 "https://releases.nixos.org/nixos/unstable/abc1234"
               )
    end

    test "find_by_base_url returns nil when no match", %{pid: pid} do
      releases = [
        %Release{
          base_url: "https://releases.nixos.org/nixos/unstable/abc1234",
          released_at: ~U[2025-03-02 10:00:00Z],
          revision: "abc1234" <> String.duplicate("0", 33)
        }
      ]

      ReleaseCache.put_releases(pid, "nixos-unstable", releases)

      assert ReleaseCache.find_by_base_url(
               pid,
               "nixos-unstable",
               "https://releases.nixos.org/nixos/unstable/nonexistent"
             ) == nil
    end

    test "find_by_base_url returns nil for unknown channel", %{pid: pid} do
      assert ReleaseCache.find_by_base_url(pid, "nonexistent", "https://example.com/foo") == nil
    end

    test "find_by_revision returns release matching exact revision", %{pid: pid} do
      abc_rev = "abc1234" <> String.duplicate("0", 33)

      releases = [
        %Release{
          base_url: "https://releases.nixos.org/nixos/unstable/abc1234",
          released_at: ~U[2025-03-02 10:00:00Z],
          revision: abc_rev
        },
        %Release{
          base_url: "https://releases.nixos.org/nixos/unstable/def5678",
          released_at: ~U[2025-03-01 10:00:00Z],
          revision: "def5678" <> String.duplicate("0", 33)
        }
      ]

      ReleaseCache.put_releases(pid, "nixos-unstable", releases)

      assert %Release{revision: ^abc_rev} =
               ReleaseCache.find_by_revision(pid, "nixos-unstable", abc_rev)
    end

    test "find_by_revision returns nil when no match", %{pid: pid} do
      releases = [
        %Release{
          base_url: "https://releases.nixos.org/nixos/unstable/abc1234",
          released_at: ~U[2025-03-02 10:00:00Z],
          revision: "abc1234" <> String.duplicate("0", 33)
        }
      ]

      ReleaseCache.put_releases(pid, "nixos-unstable", releases)

      assert ReleaseCache.find_by_revision(
               pid,
               "nixos-unstable",
               "zzz999" <> String.duplicate("0", 34)
             ) == nil
    end

    test "put_pointer and get_pointer round-trip", %{pid: pid} do
      pointer = %{
        etag: ~s("abc"),
        last_modified: "Wed, 21 May 2026 12:00:00 GMT",
        revision: "rev1"
      }

      assert :ok = ReleaseCache.put_pointer(pid, "nixos-unstable", pointer)
      assert ReleaseCache.get_pointer(pid, "nixos-unstable") == pointer
    end

    test "get_pointer returns nil for unknown channel", %{pid: pid} do
      assert ReleaseCache.get_pointer(pid, "nonexistent") == nil
    end

    test "newest_revision returns the revision of the first release", %{pid: pid} do
      newest = "ccc" <> String.duplicate("0", 37)

      releases = [
        %Release{
          base_url: "https://example.com/c",
          released_at: ~U[2025-03-03 10:00:00Z],
          revision: newest
        },
        %Release{
          base_url: "https://example.com/b",
          released_at: ~U[2025-03-02 10:00:00Z],
          revision: "bbb" <> String.duplicate("0", 37)
        }
      ]

      ReleaseCache.put_releases(pid, "nixos-unstable", releases)
      assert ReleaseCache.newest_revision(pid, "nixos-unstable") == newest
    end

    test "newest_revision returns nil for unknown or empty channel", %{pid: pid} do
      assert ReleaseCache.newest_revision(pid, "nonexistent") == nil
      ReleaseCache.put_releases(pid, "empty", [])
      assert ReleaseCache.newest_revision(pid, "empty") == nil
    end
  end

  describe "refresh_channel/2" do
    setup do
      pid = start_supervised!({ReleaseCache, name: nil})
      %{pid: pid}
    end

    test "fetches a single channel's releases without touching others", %{pid: pid} do
      preexisting = [
        %Release{
          base_url: "https://example.com/other",
          released_at: ~U[2025-03-01 10:00:00Z],
          revision: "other" <> String.duplicate("0", 35)
        }
      ]

      ReleaseCache.put_releases(pid, "other-channel", preexisting)

      fresh = [
        %Release{
          base_url: "https://releases.nixos.org/nixos/unstable/nixos-25.05pre-zzz",
          released_at: ~U[2025-06-15 10:00:00Z],
          revision: "zzz" <> String.duplicate("0", 37)
        }
      ]

      releases_fetcher = fn "nixos-unstable" -> fresh end

      assert :ok =
               ReleaseCache.refresh_channel(pid, "nixos-unstable",
                 releases_fetcher: releases_fetcher
               )

      assert ReleaseCache.get_releases(pid, "nixos-unstable") == fresh
      assert ReleaseCache.get_releases(pid, "other-channel") == preexisting
    end
  end

  describe "parse_releases/1" do
    test "parses released_at to DateTime" do
      contents = [
        %{
          "Key" => "nixos/unstable/nixos-unstable-new.abc1234",
          "LastModified" => "2025-06-15T10:00:00Z"
        }
      ]

      [release] = ReleaseCache.parse_releases(contents)

      assert %DateTime{} = release.released_at
      assert release.released_at == ~U[2025-06-15 10:00:00Z]
    end
  end

  describe "release cutoff" do
    test "parse_releases excludes releases older than the default cutoff (2020-03-27)" do
      contents = [
        %{
          "Key" => "nixos/unstable/nixos-unstable-new.abc1234",
          "LastModified" => "2020-06-01T10:00:00Z"
        },
        %{
          "Key" => "nixos/unstable/nixos-unstable-old.def5678",
          "LastModified" => "2020-01-01T23:59:59Z"
        }
      ]

      releases = ReleaseCache.parse_releases(contents)

      assert length(releases) == 1
      assert hd(releases).base_url =~ "abc1234"
    end

    test "parse_releases accepts an earlier `from` to include older releases" do
      contents = [
        %{
          "Key" => "nixos/unstable/nixos-unstable-new.abc1234",
          "LastModified" => "2025-06-15T10:00:00Z"
        },
        %{
          "Key" => "nixos/unstable/nixos-unstable-old.def5678",
          "LastModified" => "2021-05-01T00:00:00Z"
        }
      ]

      releases = ReleaseCache.parse_releases(contents, ~U[2020-03-27 00:00:00Z])

      assert length(releases) == 2
    end

    test "parse_releases excludes releases newer than `until`, bounding a window" do
      contents = [
        %{
          "Key" => "nixos/unstable/nixos-unstable-late.aaa",
          "LastModified" => "2021-09-01T00:00:00Z"
        },
        %{
          "Key" => "nixos/unstable/nixos-unstable-early.bbb",
          "LastModified" => "2021-04-01T00:00:00Z"
        }
      ]

      releases =
        ReleaseCache.parse_releases(contents, ~U[2021-01-01 00:00:00Z], ~U[2021-06-01 00:00:00Z])

      assert length(releases) == 1
      assert hd(releases).base_url =~ "bbb"
    end
  end
end

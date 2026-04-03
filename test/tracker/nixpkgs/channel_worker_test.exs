defmodule Tracker.Nixpkgs.ChannelWorkerTest do
  use Tracker.DataCase, async: true

  alias Tracker.Nixpkgs.ChannelWorker

  describe "write_to_database with maintainers and teams" do
    test "creates package_maintainers for nonTeamMaintainers" do
      data = %{
        "version" => 2,
        "revision" => "abc123",
        "channel" => "nixos-unstable-small",
        "released_at" => "2026-03-29T10:00:00Z",
        "packages" => %{
          "hello" => %{
            "version" => "2.12.1",
            "meta" => %{
              "description" => "A program that produces a familiar greeting",
              "homepage" => "https://www.gnu.org/software/hello/",
              "nonTeamMaintainers" => [
                %{
                  "githubId" => 1001,
                  "name" => "Alice",
                  "github" => "alice",
                  "email" => "alice@example.com"
                },
                %{
                  "githubId" => 1002,
                  "name" => "Bob",
                  "github" => "bob",
                  "email" => "bob@example.com"
                }
              ],
              "teams" => nil,
              "maintainers" => [
                %{
                  "githubId" => 1001,
                  "name" => "Alice",
                  "github" => "alice",
                  "email" => "alice@example.com"
                },
                %{
                  "githubId" => 1002,
                  "name" => "Bob",
                  "github" => "bob",
                  "email" => "bob@example.com"
                }
              ]
            }
          }
        }
      }

      ChannelWorker.write_to_database(data)

      package = Ash.get!(Tracker.Nixpkgs.Package, %{attribute: "hello"})
      package = Ash.load!(package, [:maintainers, teams: [:members]])

      assert length(package.maintainers) == 2
      maintainer_githubs = Enum.map(package.maintainers, & &1.github) |> Enum.sort()
      assert maintainer_githubs == ["alice", "bob"]
      assert package.teams == []
    end

    test "creates package_teams and team_members for teams" do
      data = %{
        "version" => 2,
        "revision" => "def456",
        "channel" => "nixos-unstable-small",
        "released_at" => "2026-03-29T10:00:00Z",
        "packages" => %{
          "incus" => %{
            "version" => "6.0",
            "meta" => %{
              "nonTeamMaintainers" => [],
              "teams" => [
                %{
                  "shortName" => "TestLXC",
                  "scope" => "LXC, Incus",
                  "github" => "lxc",
                  "githubId" => 9999,
                  "members" => [
                    %{
                      "githubId" => 2001,
                      "name" => "Carol",
                      "github" => "carol",
                      "email" => "carol@example.com"
                    },
                    %{
                      "githubId" => 2002,
                      "name" => "Dave",
                      "github" => "dave",
                      "email" => "dave@example.com"
                    }
                  ],
                  "githubMaintainers" => []
                }
              ],
              "maintainers" => [
                %{
                  "githubId" => 2001,
                  "name" => "Carol",
                  "github" => "carol",
                  "email" => "carol@example.com"
                },
                %{
                  "githubId" => 2002,
                  "name" => "Dave",
                  "github" => "dave",
                  "email" => "dave@example.com"
                }
              ]
            }
          }
        }
      }

      ChannelWorker.write_to_database(data)

      package = Ash.get!(Tracker.Nixpkgs.Package, %{attribute: "incus"})
      package = Ash.load!(package, [:maintainers, teams: [:members]])

      assert package.maintainers == []
      assert length(package.teams) == 1

      team = hd(package.teams)
      assert to_string(team.short_name) == "testlxc"
      assert team.scope == "LXC, Incus"

      member_githubs = Enum.map(team.members, & &1.github) |> Enum.sort()
      assert member_githubs == ["carol", "dave"]
    end

    test "handles packages with multiple maintainers across batch boundaries" do
      # 3 shared maintainers across 6000 packages = 18000 join rows
      maintainers =
        for i <- 1..3 do
          %{
            "githubId" => 50_000 + i,
            "name" => "Maint#{i}",
            "github" => "maint#{i}",
            "email" => "m#{i}@example.com"
          }
        end

      packages =
        for i <- 1..6000, into: %{} do
          {"pkg-#{i}",
           %{
             "version" => "1.0.#{i}",
             "meta" => %{
               "nonTeamMaintainers" => maintainers,
               "teams" => nil,
               "maintainers" => maintainers
             }
           }}
        end

      data = %{
        "version" => 2,
        "revision" => "batch123",
        "channel" => "nixos-unstable-small",
        "released_at" => "2026-03-29T10:00:00Z",
        "packages" => packages
      }

      ChannelWorker.write_to_database(data)

      pm_count =
        Tracker.Nixpkgs.PackageMaintainer
        |> Ash.read!()
        |> length()

      assert pm_count == 18_000
    end
  end

  describe "write_to_database with license metadata" do
    test "stores single license spdxId as list" do
      data = %{
        "version" => 2,
        "revision" => "lic001",
        "channel" => "nixos-unstable-small",
        "released_at" => "2026-03-29T10:00:00Z",
        "packages" => %{
          "firefox" => %{
            "version" => "149.0",
            "meta" => %{
              "license" => %{
                "spdxId" => "MPL-2.0",
                "fullName" => "Mozilla Public License 2.0"
              }
            }
          }
        }
      }

      ChannelWorker.write_to_database(data)

      package = Ash.get!(Tracker.Nixpkgs.Package, %{attribute: "firefox"})
      assert package.licenses == ["MPL-2.0"]
    end

    test "stores list of licenses as list of spdxIds" do
      data = %{
        "version" => 2,
        "revision" => "lic002",
        "channel" => "nixos-unstable-small",
        "released_at" => "2026-03-29T10:00:00Z",
        "packages" => %{
          "dual-pkg" => %{
            "version" => "1.0",
            "meta" => %{
              "license" => [
                %{"spdxId" => "Artistic-1.0"},
                %{"spdxId" => "GPL-1.0-or-later"}
              ]
            }
          }
        }
      }

      ChannelWorker.write_to_database(data)

      package = Ash.get!(Tracker.Nixpkgs.Package, %{attribute: "dual-pkg"})
      assert package.licenses == ["Artistic-1.0", "GPL-1.0-or-later"]
    end

    test "stores string license as list" do
      data = %{
        "version" => 2,
        "revision" => "lic003",
        "channel" => "nixos-unstable-small",
        "released_at" => "2026-03-29T10:00:00Z",
        "packages" => %{
          "unknown-pkg" => %{
            "version" => "1.0",
            "meta" => %{
              "license" => "unknown"
            }
          }
        }
      }

      ChannelWorker.write_to_database(data)

      package = Ash.get!(Tracker.Nixpkgs.Package, %{attribute: "unknown-pkg"})
      assert package.licenses == ["unknown"]
    end

    test "falls back to fullName when no spdxId" do
      data = %{
        "version" => 2,
        "revision" => "lic005",
        "channel" => "nixos-unstable-small",
        "released_at" => "2026-03-29T10:00:00Z",
        "packages" => %{
          "fullname-pkg" => %{
            "version" => "1.0",
            "meta" => %{
              "license" => %{
                "fullName" => "GPLv3+ and other free licenses"
              }
            }
          }
        }
      }

      ChannelWorker.write_to_database(data)

      package = Ash.get!(Tracker.Nixpkgs.Package, %{attribute: "fullname-pkg"})
      assert package.licenses == ["GPLv3+ and other free licenses"]
    end

    test "stores nil when no license and no family for top-level" do
      data = %{
        "version" => 2,
        "revision" => "lic004",
        "channel" => "nixos-unstable-small",
        "released_at" => "2026-03-29T10:00:00Z",
        "packages" => %{
          "no-lic-pkg" => %{
            "version" => "1.0",
            "meta" => %{}
          }
        }
      }

      ChannelWorker.write_to_database(data)

      package = Ash.get!(Tracker.Nixpkgs.Package, %{attribute: "no-lic-pkg"})
      assert package.licenses == nil
    end
  end

  describe "write_to_database with homepage metadata" do
    test "normalizes string homepage to array" do
      data = %{
        "version" => 2,
        "revision" => "hp001",
        "channel" => "nixos-unstable-small",
        "released_at" => "2026-03-29T10:00:00Z",
        "packages" => %{
          "hello" => %{
            "version" => "2.12.1",
            "meta" => %{
              "homepage" => "https://www.gnu.org/software/hello/"
            }
          }
        }
      }

      ChannelWorker.write_to_database(data)

      package = Ash.get!(Tracker.Nixpkgs.Package, %{attribute: "hello"})
      assert package.homepage == ["https://www.gnu.org/software/hello/"]
    end

    test "stores list homepage as array" do
      data = %{
        "version" => 2,
        "revision" => "hp002",
        "channel" => "nixos-unstable-small",
        "released_at" => "2026-03-29T10:00:00Z",
        "packages" => %{
          "osmtools" => %{
            "version" => "1.0",
            "meta" => %{
              "homepage" => [
                "https://wiki.openstreetmap.org/wiki/osmconvert",
                "https://wiki.openstreetmap.org/wiki/osmfilter"
              ]
            }
          }
        }
      }

      ChannelWorker.write_to_database(data)

      package = Ash.get!(Tracker.Nixpkgs.Package, %{attribute: "osmtools"})

      assert package.homepage == [
               "https://wiki.openstreetmap.org/wiki/osmconvert",
               "https://wiki.openstreetmap.org/wiki/osmfilter"
             ]
    end

    test "stores nil when no homepage" do
      data = %{
        "version" => 2,
        "revision" => "hp003",
        "channel" => "nixos-unstable-small",
        "released_at" => "2026-03-29T10:00:00Z",
        "packages" => %{
          "no-hp-pkg" => %{
            "version" => "1.0",
            "meta" => %{}
          }
        }
      }

      ChannelWorker.write_to_database(data)

      package = Ash.get!(Tracker.Nixpkgs.Package, %{attribute: "no-hp-pkg"})
      assert package.homepage == nil
    end
  end

  describe "write_to_database with nil version" do
    test "skips packages with nil version" do
      data = %{
        "version" => 2,
        "revision" => "nil001",
        "channel" => "nixos-unstable",
        "released_at" => "2026-03-29T10:00:00Z",
        "packages" => %{
          "hello" => %{"version" => "2.12"},
          "rPackages.MarketMatching" => %{
            "name" => "r-MarketMatching",
            "system" => "x86_64-linux",
            "meta" => %{}
          }
        }
      }

      ChannelWorker.write_to_database(data)

      hello = Ash.get!(Tracker.Nixpkgs.Package, %{attribute: "hello"})
      assert hello != nil

      # Package without version should not have a package_revision
      assert {:error, _} =
               Ash.get(Tracker.Nixpkgs.Package, %{attribute: "rPackages.MarketMatching"})
    end
  end

  describe "write_to_database with package events" do
    alias Tracker.Nixpkgs.ReleaseCache
    alias Tracker.Nixpkgs.ReleaseCache.Release

    test "generates added events when packages appear in a new revision" do
      ReleaseCache.put_releases("nixos-unstable", [
        %Release{
          short_hash: "evt002",
          base_url: "https://example.com/evt002",
          released_at: "2026-03-02T10:00:00Z"
        },
        %Release{
          short_hash: "evt001",
          base_url: "https://example.com/evt001",
          released_at: "2026-03-01T10:00:00Z"
        }
      ])

      # First revision: baseline, no events
      data1 = %{
        "version" => 2,
        "revision" => "evt001",
        "channel" => "nixos-unstable",
        "released_at" => "2026-03-01T10:00:00Z",
        "packages" => %{
          "hello" => %{"version" => "2.12"},
          "curl" => %{"version" => "8.0"}
        }
      }

      ChannelWorker.write_to_database(data1)

      assert Tracker.Nixpkgs.PackageEvent.list!() == []

      # Second revision: adds "git", keeps "hello" and "curl"
      data2 = %{
        "version" => 2,
        "revision" => "evt002",
        "channel" => "nixos-unstable",
        "released_at" => "2026-03-02T10:00:00Z",
        "packages" => %{
          "hello" => %{"version" => "2.12"},
          "curl" => %{"version" => "8.0"},
          "git" => %{"version" => "2.44"}
        }
      }

      ChannelWorker.write_to_database(data2)

      events = Tracker.Nixpkgs.PackageEvent.list!()
      assert length(events) == 1

      event = hd(events)
      git_pkg = Ash.get!(Tracker.Nixpkgs.Package, %{attribute: "git"})
      assert event.type == :added
      assert event.package_id == git_pkg.id
    end

    test "generates removed events when packages disappear from a revision" do
      ReleaseCache.put_releases("nixos-unstable", [
        %Release{
          short_hash: "evr002",
          base_url: "https://example.com/evr002",
          released_at: "2026-03-02T10:00:00Z"
        },
        %Release{
          short_hash: "evr001",
          base_url: "https://example.com/evr001",
          released_at: "2026-03-01T10:00:00Z"
        }
      ])

      data1 = %{
        "version" => 2,
        "revision" => "evr001",
        "channel" => "nixos-unstable",
        "released_at" => "2026-03-01T10:00:00Z",
        "packages" => %{
          "hello" => %{"version" => "2.12"},
          "curl" => %{"version" => "8.0"}
        }
      }

      ChannelWorker.write_to_database(data1)

      # Second revision: removes "curl"
      data2 = %{
        "version" => 2,
        "revision" => "evr002",
        "channel" => "nixos-unstable",
        "released_at" => "2026-03-02T10:00:00Z",
        "packages" => %{
          "hello" => %{"version" => "2.12"}
        }
      }

      ChannelWorker.write_to_database(data2)

      events = Tracker.Nixpkgs.PackageEvent.list!()
      assert length(events) == 1

      event = hd(events)
      curl_pkg = Ash.get!(Tracker.Nixpkgs.Package, %{attribute: "curl"})
      assert event.type == :removed
      assert event.package_id == curl_pkg.id
    end

    test "does not generate events for first revision of a channel" do
      data = %{
        "version" => 2,
        "revision" => "first001",
        "channel" => "nixos-new-channel",
        "released_at" => "2026-03-01T10:00:00Z",
        "packages" => %{
          "hello" => %{"version" => "2.12"},
          "curl" => %{"version" => "8.0"}
        }
      }

      ChannelWorker.write_to_database(data)

      events = Tracker.Nixpkgs.PackageEvent.list!()
      assert events == []
    end

    test "stores previous_channel_revision_id on channel revision" do
      # Use a unique channel name to avoid interference from other async tests
      channel = "nixos-prev-test-#{System.unique_integer([:positive])}"

      ReleaseCache.put_releases(channel, [
        %Release{
          short_hash: "prev002abcde",
          base_url: "https://example.com/prev002abcde",
          released_at: "2026-03-02T10:00:00Z"
        },
        %Release{
          short_hash: "prev001abcde",
          base_url: "https://example.com/prev001abcde",
          released_at: "2026-03-01T10:00:00Z"
        }
      ])

      rev1_hash = "prev001abcdef1234567890123456789012345678"

      data1 = %{
        "version" => 2,
        "revision" => rev1_hash,
        "channel" => channel,
        "released_at" => "2026-03-01T10:00:00Z",
        "packages" => %{"hello" => %{"version" => "2.12"}}
      }

      ChannelWorker.write_to_database(data1)

      rev1 =
        Ash.get!(Tracker.Nixpkgs.ChannelRevision, %{
          channel: channel,
          revision: rev1_hash
        })

      assert rev1.previous_channel_revision_id == nil

      rev2_hash = "prev002abcdef1234567890123456789012345678"

      data2 = %{
        "version" => 2,
        "revision" => rev2_hash,
        "channel" => channel,
        "released_at" => "2026-03-02T10:00:00Z",
        "packages" => %{"hello" => %{"version" => "2.12"}}
      }

      ChannelWorker.write_to_database(data2)

      rev2 =
        Ash.get!(Tracker.Nixpkgs.ChannelRevision, %{
          channel: channel,
          revision: rev2_hash
        })

      assert rev2.previous_channel_revision_id == rev1.id
    end
  end

  describe "backfill_channel/2" do
    alias Tracker.Nixpkgs.ReleaseCache
    alias Tracker.Nixpkgs.ReleaseCache.Release

    setup do
      ReleaseCache.put_releases("nixos-test", [
        %Release{
          short_hash: "ccc3333",
          base_url: "https://releases.nixos.org/nixos/test/test.ccc3333",
          released_at: "2026-03-03T10:00:00Z"
        },
        %Release{
          short_hash: "bbb2222",
          base_url: "https://releases.nixos.org/nixos/test/test.bbb2222",
          released_at: "2026-03-02T10:00:00Z"
        },
        %Release{
          short_hash: "aaa1111",
          base_url: "https://releases.nixos.org/nixos/test/test.aaa1111",
          released_at: "2026-03-01T10:00:00Z"
        }
      ])

      :ok
    end

    test "inserts one job with oldest release first and remaining count" do
      assert {:ok, 3} = ChannelWorker.backfill_channel("nixos-test")

      # Oldest release should be scheduled first
      assert_enqueued(
        worker: Tracker.Nixpkgs.ChannelWorker,
        args: %{
          "channel" => "nixos-test",
          "base_url" => "https://releases.nixos.org/nixos/test/test.aaa1111",
          "released_at" => "2026-03-01T10:00:00Z",
          "remaining" => 2
        }
      )
    end

    test "limit takes the oldest N releases" do
      assert {:ok, 2} = ChannelWorker.backfill_channel("nixos-test", limit: 2)

      assert_enqueued(
        worker: Tracker.Nixpkgs.ChannelWorker,
        args: %{"channel" => "nixos-test", "remaining" => 1}
      )
    end

    test "returns {:ok, 0} and inserts no jobs when all releases exist" do
      # Pre-populate all revisions
      for {rev, date} <- [
            {"aaa1111", "2026-03-01T10:00:00Z"},
            {"bbb2222", "2026-03-02T10:00:00Z"},
            {"ccc3333", "2026-03-03T10:00:00Z"}
          ] do
        Tracker.Nixpkgs.ChannelRevision.create!(%{
          revision: rev,
          channel: "nixos-test",
          released_at: date
        })
      end

      assert {:ok, 0} = ChannelWorker.backfill_channel("nixos-test")

      refute_enqueued(worker: Tracker.Nixpkgs.ChannelWorker, args: %{"channel" => "nixos-test"})
    end
  end

  describe "schedule_next/1" do
    alias Tracker.Nixpkgs.ReleaseCache
    alias Tracker.Nixpkgs.ReleaseCache.Release

    setup do
      ReleaseCache.put_releases("nixos-test", [
        %Release{
          short_hash: "ccc3333",
          base_url: "https://releases.nixos.org/nixos/test/test.ccc3333",
          released_at: "2026-03-03T10:00:00Z"
        },
        %Release{
          short_hash: "bbb2222",
          base_url: "https://releases.nixos.org/nixos/test/test.bbb2222",
          released_at: "2026-03-02T10:00:00Z"
        },
        %Release{
          short_hash: "aaa1111",
          base_url: "https://releases.nixos.org/nixos/test/test.aaa1111",
          released_at: "2026-03-01T10:00:00Z"
        }
      ])

      :ok
    end

    test "schedules next release from ReleaseCache" do
      args = %{
        "channel" => "nixos-test",
        "base_url" => "https://releases.nixos.org/nixos/test/test.aaa1111",
        "remaining" => 2
      }

      ChannelWorker.schedule_next(args)

      assert_enqueued(
        worker: Tracker.Nixpkgs.ChannelWorker,
        args: %{
          "channel" => "nixos-test",
          "released_at" => "2026-03-02T10:00:00Z",
          "remaining" => 1
        }
      )
    end

    test "is a no-op when remaining is 0" do
      args = %{
        "channel" => "nixos-test",
        "base_url" => "https://releases.nixos.org/nixos/test/test.ccc3333",
        "remaining" => 0
      }

      ChannelWorker.schedule_next(args)

      refute_enqueued(worker: Tracker.Nixpkgs.ChannelWorker, args: %{"channel" => "nixos-test"})
    end

    test "is a no-op when remaining key is absent" do
      args = %{
        "channel" => "nixos-test",
        "base_url" => "https://releases.nixos.org/nixos/test/test.aaa1111"
      }

      ChannelWorker.schedule_next(args)

      refute_enqueued(worker: Tracker.Nixpkgs.ChannelWorker, args: %{"channel" => "nixos-test"})
    end
  end

  describe "write_to_database without released_at" do
    test "falls back to current time when released_at is not provided" do
      data = %{
        "version" => 2,
        "revision" => "nodate001",
        "channel" => "nixos-unstable",
        "packages" => %{
          "hello" => %{"version" => "2.12"}
        }
      }

      before = DateTime.utc_now() |> DateTime.truncate(:second)
      ChannelWorker.write_to_database(data)
      after_time = DateTime.utc_now() |> DateTime.add(1, :second) |> DateTime.truncate(:second)

      rev =
        Ash.get!(Tracker.Nixpkgs.ChannelRevision, %{
          channel: "nixos-unstable",
          revision: "nodate001"
        })

      assert DateTime.compare(rev.released_at, before) in [:gt, :eq]
      assert DateTime.compare(rev.released_at, after_time) in [:lt, :eq]
    end
  end

  describe "write_to_database broadcasts on success" do
    test "broadcasts on the channel_revisions topic after success" do
      Phoenix.PubSub.subscribe(Tracker.PubSub, "channel_revisions:nixos-unstable")

      data = %{
        "version" => 2,
        "revision" => "pub001",
        "channel" => "nixos-unstable",
        "released_at" => "2026-03-29T10:00:00Z",
        "packages" => %{
          "hello" => %{"version" => "2.12"}
        }
      }

      ChannelWorker.write_to_database(data)

      assert_receive {:channel_revision_completed,
                      %{channel: "nixos-unstable", revision: "pub001"}}
    end
  end

  describe "write_to_database options worker scheduling" do
    test "schedules options worker for nixos channels" do
      data = %{
        "version" => 2,
        "revision" => "opt001",
        "channel" => "nixos-unstable",
        "base_url" => "https://releases.nixos.org/nixos/unstable/nixos-25.05pre123.abc123",
        "released_at" => "2026-03-29T10:00:00Z",
        "packages" => %{
          "hello" => %{"version" => "2.12"}
        }
      }

      ChannelWorker.write_to_database(data)

      assert_enqueued(
        worker: Tracker.Nixpkgs.OptionsWorker,
        args: %{"channel" => "nixos-unstable", "revision" => "opt001"}
      )
    end

    test "does not schedule options worker for nixpkgs channels" do
      data = %{
        "version" => 2,
        "revision" => "opt002",
        "channel" => "nixpkgs-unstable",
        "base_url" => "https://releases.nixos.org/nixpkgs/nixpkgs-26.05pre123.abc123",
        "released_at" => "2026-03-29T10:00:00Z",
        "packages" => %{
          "hello" => %{"version" => "2.12"}
        }
      }

      ChannelWorker.write_to_database(data)

      refute_enqueued(
        worker: Tracker.Nixpkgs.OptionsWorker,
        args: %{"channel" => "nixpkgs-unstable"}
      )
    end
  end

  describe "write_to_database with package families" do
    test "creates package families for dotted attributes" do
      data = %{
        "version" => 2,
        "revision" => "fam001",
        "channel" => "nixos-unstable",
        "released_at" => "2026-03-29T10:00:00Z",
        "packages" => %{
          "python313Packages.numpy" => %{"version" => "2.3.4"},
          "python312Packages.numpy" => %{"version" => "1.26.4"},
          "python313Packages.requests" => %{"version" => "2.32.0"}
        }
      }

      ChannelWorker.write_to_database(data)

      numpy_313 = Ash.get!(Tracker.Nixpkgs.Package, %{attribute: "python313Packages.numpy"})
      numpy_312 = Ash.get!(Tracker.Nixpkgs.Package, %{attribute: "python312Packages.numpy"})
      requests = Ash.get!(Tracker.Nixpkgs.Package, %{attribute: "python313Packages.requests"})

      # Both numpy packages share the same family
      assert numpy_313.package_family_id != nil
      assert numpy_313.package_family_id == numpy_312.package_family_id

      # requests has a different family
      assert requests.package_family_id != nil
      assert requests.package_family_id != numpy_313.package_family_id

      # Package set and version are populated
      assert numpy_313.package_set == "python313Packages"
      assert numpy_313.set_version == "3.13"
      assert numpy_312.package_set == "python312Packages"
      assert numpy_312.set_version == "3.12"
    end

    test "does not create family for undotted top-level packages" do
      data = %{
        "version" => 2,
        "revision" => "fam002",
        "channel" => "nixos-unstable",
        "released_at" => "2026-03-29T10:00:00Z",
        "packages" => %{
          "vim" => %{"version" => "9.1"},
          "git" => %{"version" => "2.44"}
        }
      }

      ChannelWorker.write_to_database(data)

      vim = Ash.get!(Tracker.Nixpkgs.Package, %{attribute: "vim"})
      git = Ash.get!(Tracker.Nixpkgs.Package, %{attribute: "git"})

      assert vim.package_family_id == nil
      assert vim.package_set == nil
      assert git.package_family_id == nil
    end

    test "creates family for top-level runtime packages" do
      data = %{
        "version" => 2,
        "revision" => "fam003",
        "channel" => "nixos-unstable",
        "released_at" => "2026-03-29T10:00:00Z",
        "packages" => %{
          "python311" => %{"version" => "3.11.8"},
          "python312" => %{"version" => "3.12.2"}
        }
      }

      ChannelWorker.write_to_database(data)

      py311 = Ash.get!(Tracker.Nixpkgs.Package, %{attribute: "python311"})
      py312 = Ash.get!(Tracker.Nixpkgs.Package, %{attribute: "python312"})

      assert py311.package_family_id != nil
      assert py311.package_family_id == py312.package_family_id
      assert py311.set_version == "3.11"
      assert py312.set_version == "3.12"
    end
  end

  describe "write_to_database with package variant groups" do
    test "groups top-level packages sharing the same position" do
      data = %{
        "version" => 2,
        "revision" => "var001",
        "channel" => "nixos-unstable-small",
        "released_at" => "2026-04-01T10:00:00Z",
        "packages" => %{
          "ffmpeg_7" => %{
            "version" => "7.1",
            "meta" => %{"position" => "pkgs/libraries/ffmpeg/generic.nix:100"}
          },
          "ffmpeg_8" => %{
            "version" => "8.0",
            "meta" => %{"position" => "pkgs/libraries/ffmpeg/generic.nix:100"}
          },
          "ffmpeg_4" => %{
            "version" => "4.4",
            "meta" => %{"position" => "pkgs/libraries/ffmpeg/generic.nix:100"}
          }
        }
      }

      ChannelWorker.write_to_database(data)

      ffmpeg_7 = Ash.get!(Tracker.Nixpkgs.Package, %{attribute: "ffmpeg_7"})
      ffmpeg_8 = Ash.get!(Tracker.Nixpkgs.Package, %{attribute: "ffmpeg_8"})
      ffmpeg_4 = Ash.get!(Tracker.Nixpkgs.Package, %{attribute: "ffmpeg_4"})

      assert ffmpeg_7.package_variant_group_id != nil
      assert ffmpeg_7.package_variant_group_id == ffmpeg_8.package_variant_group_id
      assert ffmpeg_7.package_variant_group_id == ffmpeg_4.package_variant_group_id
    end

    test "does not group packages in a package set" do
      data = %{
        "version" => 2,
        "revision" => "var002",
        "channel" => "nixos-unstable-small",
        "released_at" => "2026-04-01T10:00:00Z",
        "packages" => %{
          "linuxPackages.zfs" => %{
            "version" => "2.2.4",
            "meta" => %{"position" => "pkgs/os-specific/linux/zfs/generic.nix:50"}
          },
          "linuxPackages_zen.zfs" => %{
            "version" => "2.2.4",
            "meta" => %{"position" => "pkgs/os-specific/linux/zfs/generic.nix:50"}
          }
        }
      }

      ChannelWorker.write_to_database(data)

      zfs1 = Ash.get!(Tracker.Nixpkgs.Package, %{attribute: "linuxPackages.zfs"})
      zfs2 = Ash.get!(Tracker.Nixpkgs.Package, %{attribute: "linuxPackages_zen.zfs"})

      assert zfs1.package_variant_group_id == nil
      assert zfs2.package_variant_group_id == nil
    end

    test "does not group a single package with unique position" do
      data = %{
        "version" => 2,
        "revision" => "var003",
        "channel" => "nixos-unstable-small",
        "released_at" => "2026-04-01T10:00:00Z",
        "packages" => %{
          "hello" => %{
            "version" => "2.12.1",
            "meta" => %{"position" => "pkgs/by-name/he/hello/package.nix:10"}
          },
          "curl" => %{
            "version" => "8.7.1",
            "meta" => %{"position" => "pkgs/by-name/cu/curl/package.nix:50"}
          }
        }
      }

      ChannelWorker.write_to_database(data)

      hello = Ash.get!(Tracker.Nixpkgs.Package, %{attribute: "hello"})
      curl = Ash.get!(Tracker.Nixpkgs.Package, %{attribute: "curl"})

      assert hello.package_variant_group_id == nil
      assert curl.package_variant_group_id == nil
    end

    test "does not group packages without a position" do
      data = %{
        "version" => 2,
        "revision" => "var004",
        "channel" => "nixos-unstable",
        "released_at" => "2026-04-01T10:00:00Z",
        "packages" => %{
          "nopos-a" => %{"version" => "1.0"},
          "nopos-b" => %{"version" => "2.0"}
        }
      }

      ChannelWorker.write_to_database(data)

      a = Ash.get!(Tracker.Nixpkgs.Package, %{attribute: "nopos-a"})
      b = Ash.get!(Tracker.Nixpkgs.Package, %{attribute: "nopos-b"})

      assert a.package_variant_group_id == nil
      assert b.package_variant_group_id == nil
    end
  end
end

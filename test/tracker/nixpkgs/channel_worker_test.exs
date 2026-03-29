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
      maintainer_names = Enum.map(package.maintainers, & &1.name) |> Enum.sort()
      assert maintainer_names == ["Alice", "Bob"]
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
      assert team.short_name == "TestLXC"
      assert team.scope == "LXC, Incus"

      member_names = Enum.map(team.members, & &1.name) |> Enum.sort()
      assert member_names == ["Carol", "Dave"]
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

      require Ash.Query

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
end

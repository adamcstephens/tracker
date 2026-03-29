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
end

defmodule Tracker.PackageStreamFixtures do
  @moduledoc """
  Test fixtures for PackageStream NIF tests.

  Builds minimal packages.json structures covering edge cases,
  brotli-compresses them with ExBrotli.
  """

  @doc """
  Returns a brotli-compressed packages.json binary with a variety
  of package entries covering all edge cases.
  """
  def small_packages_br do
    json()
    |> Jason.encode!()
    |> ExBrotli.compress!()
  end

  @doc """
  Returns the raw JSON map (for reference in assertions).
  """
  def json do
    %{
      "version" => 2,
      "packages" => %{
        "hello" => %{
          "version" => "2.12.1",
          "meta" => %{
            "description" => "A program that produces a familiar, friendly greeting",
            "homepage" => "https://www.gnu.org/software/hello/",
            "position" => "pkgs/by-name/he/hello/package.nix",
            "license" => [%{"spdxId" => "GPL-3.0-or-later"}]
          }
        },
        "empty_version" => %{
          "version" => ""
        },
        "null_version" => %{
          "version" => nil
        },
        "multi_homepage" => %{
          "version" => "1.0",
          "meta" => %{
            "homepage" => ["https://a.com", "https://b.com"]
          }
        },
        "complex_licenses" => %{
          "version" => "1.0",
          "meta" => %{
            "license" => [
              %{"spdxId" => "MIT"},
              %{"shortName" => "custom-short"},
              %{"fullName" => "Some Full License Name"}
            ]
          }
        },
        "string_license" => %{
          "version" => "1.0",
          "meta" => %{
            "license" => "MIT"
          }
        },
        "single_license_object" => %{
          "version" => "1.0",
          "meta" => %{
            "license" => %{"spdxId" => "Apache-2.0"}
          }
        },
        "with_maintainers" => %{
          "version" => "1.0",
          "meta" => %{
            "nonTeamMaintainers" => [
              %{"githubId" => 12345, "github" => "alice"}
            ],
            "teams" => [
              %{
                "shortName" => "NixOS-team",
                "scope" => "Maintain NixOS",
                "github" => "NixOS",
                "githubId" => 99999,
                "members" => [%{"githubId" => 67890, "github" => "bob"}]
              }
            ]
          }
        },
        "no_meta" => %{
          "version" => "3.0"
        }
      }
    }
  end

  @doc """
  Returns a brotli-compressed packages.json with `count` valid packages,
  used to exercise multi-batch streaming (batch size is 500 in the NIF).
  """
  def large_packages_br(count) do
    packages =
      Map.new(1..count, fn i ->
        {"pkg_#{i}", %{"version" => "1.0.#{i}", "meta" => %{"description" => "package #{i}"}}}
      end)

    %{"version" => 2, "packages" => packages}
    |> Jason.encode!()
    |> ExBrotli.compress!()
  end

  @doc """
  Returns a brotli-compressed packages.json with a wrong version.
  """
  def wrong_version_br do
    %{"version" => 99, "packages" => %{}}
    |> Jason.encode!()
    |> ExBrotli.compress!()
  end
end

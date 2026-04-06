defmodule Tracker.Ingestion.PackageStreamTest do
  use ExUnit.Case, async: true

  alias Tracker.Ingestion.PackageStream

  describe "stream_packages/2" do
    test "streams valid packages and skips empty/null versions" do
      br = Tracker.PackageStreamFixtures.small_packages_br()
      assert :ok = PackageStream.stream_packages(br, self())

      packages = collect_packages()
      attrs = Map.keys(packages)

      # Should have 7 valid packages (hello, multi_homepage, complex_licenses,
      # string_license, single_license_object, with_maintainers, no_meta)
      assert length(attrs) == 7

      assert "hello" in attrs
      assert "no_meta" in attrs

      # Should skip empty_version and null_version
      refute "empty_version" in attrs
      refute "null_version" in attrs
    end

    test "includes version field on all packages" do
      br = Tracker.PackageStreamFixtures.small_packages_br()
      :ok = PackageStream.stream_packages(br, self())

      packages = collect_packages()

      assert packages["hello"][:version] == "2.12.1"
      assert packages["no_meta"][:version] == "3.0"
    end

    test "normalizes string homepage to single-element list" do
      br = Tracker.PackageStreamFixtures.small_packages_br()
      :ok = PackageStream.stream_packages(br, self())

      packages = collect_packages()

      assert packages["hello"][:homepage] == ["https://www.gnu.org/software/hello/"]
    end

    test "passes through list homepage unchanged" do
      br = Tracker.PackageStreamFixtures.small_packages_br()
      :ok = PackageStream.stream_packages(br, self())

      packages = collect_packages()

      assert packages["multi_homepage"][:homepage] == ["https://a.com", "https://b.com"]
    end

    test "extracts licenses with spdxId > shortName > fullName fallback" do
      br = Tracker.PackageStreamFixtures.small_packages_br()
      :ok = PackageStream.stream_packages(br, self())

      packages = collect_packages()

      assert packages["complex_licenses"][:licenses] == [
               "MIT",
               "custom-short",
               "Some Full License Name"
             ]
    end

    test "normalizes bare string license to list" do
      br = Tracker.PackageStreamFixtures.small_packages_br()
      :ok = PackageStream.stream_packages(br, self())

      packages = collect_packages()

      assert packages["string_license"][:licenses] == ["MIT"]
    end

    test "normalizes single license object to list" do
      br = Tracker.PackageStreamFixtures.small_packages_br()
      :ok = PackageStream.stream_packages(br, self())

      packages = collect_packages()

      assert packages["single_license_object"][:licenses] == ["Apache-2.0"]
    end

    test "includes description and position" do
      br = Tracker.PackageStreamFixtures.small_packages_br()
      :ok = PackageStream.stream_packages(br, self())

      packages = collect_packages()

      assert packages["hello"][:description] ==
               "A program that produces a familiar, friendly greeting"

      assert packages["hello"][:position] == "pkgs/by-name/he/hello/package.nix"
    end

    test "includes maintainer data" do
      br = Tracker.PackageStreamFixtures.small_packages_br()
      :ok = PackageStream.stream_packages(br, self())

      packages = collect_packages()
      pkg = packages["with_maintainers"]

      assert [%{github_id: 12345, github: "alice"}] = pkg[:maintainers]
    end

    test "includes team data with members" do
      br = Tracker.PackageStreamFixtures.small_packages_br()
      :ok = PackageStream.stream_packages(br, self())

      packages = collect_packages()
      pkg = packages["with_maintainers"]

      assert [team] = pkg[:teams]
      assert team[:short_name] == "NixOS-team"
      assert team[:scope] == "Maintain NixOS"
      assert team[:github] == "NixOS"
      assert team[:github_id] == 99999
      assert [%{github_id: 67890, github: "bob"}] = team[:members]
    end

    test "sends done message with version at the end" do
      br = Tracker.PackageStreamFixtures.small_packages_br()
      :ok = PackageStream.stream_packages(br, self())

      messages = collect_all_messages()
      done_msgs = Enum.filter(messages, &match?({:done, _}, &1))

      assert [done] = done_msgs
      assert {:done, %{version: 2}} = done
    end

    test "sends error on invalid brotli data" do
      :ok = PackageStream.stream_packages("not brotli data", self())

      assert_receive {:error, reason}, 5_000
      assert is_binary(reason)
    end

    test "sends error when version != 2" do
      br = Tracker.PackageStreamFixtures.wrong_version_br()
      :ok = PackageStream.stream_packages(br, self())

      assert_receive {:error, reason}, 5_000
      assert reason =~ "version"
    end

    test "packages without meta have nil optional fields" do
      br = Tracker.PackageStreamFixtures.small_packages_br()
      :ok = PackageStream.stream_packages(br, self())

      packages = collect_packages()
      pkg = packages["no_meta"]

      assert pkg[:version] == "3.0"
      assert is_nil(pkg[:description])
      assert is_nil(pkg[:homepage])
      assert is_nil(pkg[:position])
      assert is_nil(pkg[:licenses])
      assert is_nil(pkg[:maintainers])
      assert is_nil(pkg[:teams])
    end
  end

  # Collects {:package, attr, fields} messages until {:done, _}.
  # Returns a map of %{attribute => fields}.
  defp collect_packages(acc \\ %{}) do
    receive do
      {:package, attr, fields} ->
        collect_packages(Map.put(acc, attr, fields))

      {:done, _meta} ->
        acc

      {:error, reason} ->
        raise "PackageStream NIF error: #{reason}"
    after
      10_000 ->
        raise "Timed out waiting for package stream messages"
    end
  end

  # Collects all messages until no more arrive.
  defp collect_all_messages(acc \\ []) do
    receive do
      msg -> collect_all_messages([msg | acc])
    after
      5_000 -> Enum.reverse(acc)
    end
  end
end

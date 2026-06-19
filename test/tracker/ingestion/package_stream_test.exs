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

    test "sends packages in batched messages" do
      br = Tracker.PackageStreamFixtures.small_packages_br()
      :ok = PackageStream.stream_packages(br, self())

      messages = collect_all_messages()
      batch_msgs = Enum.filter(messages, &match?({:packages, _}, &1))

      # With 7 packages and batch size 500, should be 1 batch
      assert length(batch_msgs) >= 1

      # Each batch is a list of {attr, fields} tuples
      {:packages, first_batch} = hd(batch_msgs)
      assert is_list(first_batch)
      assert {attr, fields} = hd(first_batch)
      assert is_binary(attr)
      assert is_map(fields)
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

    test "delivers all messages synchronously before returning :ok" do
      br = Tracker.PackageStreamFixtures.small_packages_br()
      assert :ok = PackageStream.stream_packages(br, self())

      # A synchronous DirtyCpu NIF only returns :ok once decompress + parse
      # have run to completion, so every message is already in our mailbox.
      # assert_received / `after 0` check the mailbox without blocking.
      assert_received {:packages, _}
      assert :ok = drain_until_done()
    end

    test "streams a large package set across multiple 500-entry batches" do
      count = 1200
      br = Tracker.PackageStreamFixtures.large_packages_br(count)
      assert :ok = PackageStream.stream_packages(br, self())

      batches = collect_batches()

      # 1200 packages at batch size 500 => 500 + 500 + 200, exercising the
      # per-batch OwnedEnv build/send/free across more than one batch.
      assert Enum.map(batches, &length/1) == [500, 500, 200]

      all = batches |> List.flatten() |> Map.new()
      assert map_size(all) == count
      assert all["pkg_1"][:version] == "1.0.1"
      assert all["pkg_1200"][:version] == "1.0.1200"
    end

    test "drives from a separate process while the receiver drains concurrently" do
      # Mirrors Tracker.Ingestion.Steps.LoadPackages: the blocking NIF runs in
      # a Task with this process as the receiver, so batches are drained while
      # the Task is still blocked rather than piling in the NIF caller's mailbox.
      br = Tracker.PackageStreamFixtures.small_packages_br()
      parent = self()

      task = Task.async(fn -> PackageStream.stream_packages(br, parent) end)

      packages = collect_packages()
      assert :ok = Task.await(task, 10_000)

      assert map_size(packages) == 7
      assert packages["hello"][:version] == "2.12.1"
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

  # Collects {:packages, [{attr, fields}, ...]} messages until {:done, _}.
  # Returns a map of %{attribute => fields}.
  defp collect_packages(acc \\ %{}) do
    receive do
      {:packages, entries} ->
        acc =
          Enum.reduce(entries, acc, fn {attr, fields}, a ->
            Map.put(a, attr, fields)
          end)

        collect_packages(acc)

      {:done, _meta} ->
        acc

      {:error, reason} ->
        raise "PackageStream NIF error: #{reason}"
    after
      10_000 ->
        raise "Timed out waiting for package stream messages"
    end
  end

  # Collects each {:packages, entries} batch as a separate list (preserving
  # batch boundaries) until {:done, _}. Relies on synchronous delivery: every
  # message is already in the mailbox by the time :ok returns.
  defp collect_batches(acc \\ []) do
    receive do
      {:packages, entries} -> collect_batches([entries | acc])
      {:done, _meta} -> Enum.reverse(acc)
    after
      0 -> flunk("expected all stream messages to be delivered before :ok returned")
    end
  end

  # Drains already-delivered package batches until the {:done, _} marker,
  # never blocking — an empty mailbox means messages were not delivered
  # synchronously.
  defp drain_until_done do
    receive do
      {:done, _meta} -> :ok
      {:packages, _entries} -> drain_until_done()
    after
      0 -> flunk("expected all stream messages to be delivered before :ok returned")
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

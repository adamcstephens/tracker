defmodule Tracker.Nixpkgs.ChangeArtifactRefreshWorkerTest do
  use Tracker.DataCase, async: false

  import Ecto.Query

  alias Tracker.GitHub.RateLimitCache
  alias Tracker.Nixpkgs.Change
  alias Tracker.Nixpkgs.ChangeArtifactRefreshWorker
  alias Tracker.Nixpkgs.ChangePackage
  alias Tracker.Nixpkgs.Package

  setup do
    table = :"rate_limit_cache_artifact_#{System.unique_integer([:positive])}"
    RateLimitCache.new(table)
    on_exit(fn -> if :ets.whereis(table) != :undefined, do: :ets.delete(table) end)
    %{rate_limit_table: table}
  end

  describe "run/2 with reason=merged" do
    test "replaces link set, updates status to :processed, bumps package_count", %{
      rate_limit_table: table
    } do
      change = insert_change!(number: 9001, state: :merged, merge_commit_sha: "mcsha")

      # Pre-existing (stale) link set that must be cleared.
      stale_pkg = insert_package!("legacy-pkg")
      insert_change_package!(change.id, stale_pkg.id, :changed)

      attrdiff = %{"added" => ["new-pkg-a"], "changed" => ["new-pkg-b"], "removed" => []}

      :ok =
        ChangeArtifactRefreshWorker.run(
          %{reason: "merged", number: 9001},
          rate_limit_table: table,
          attrdiff_fetcher: fn _change -> {:ok, attrdiff} end
        )

      {:ok, refreshed} = Change.get_by_number(9001)
      assert refreshed.processing_status == :processed
      assert refreshed.package_count == 2

      links =
        Tracker.Repo.all(
          from cp in ChangePackage,
            join: p in Package,
            on: p.id == cp.package_id,
            where: cp.change_id == ^change.id,
            select: {p.attribute, cp.type}
        )

      assert Enum.sort(links) == [{"new-pkg-a", :added}, {"new-pkg-b", :changed}]
    end

    test "cap enforcement: over 1000 entries writes zero rows, status :too_large", %{
      rate_limit_table: table
    } do
      change = insert_change!(number: 9002, state: :merged, merge_commit_sha: "bigsha")

      # 1001 added entries triggers the cap
      over_cap = for i <- 1..1001, do: "pkg-#{i}"
      attrdiff = %{"added" => over_cap, "changed" => [], "removed" => []}

      :ok =
        ChangeArtifactRefreshWorker.run(
          %{reason: "merged", number: 9002},
          rate_limit_table: table,
          attrdiff_fetcher: fn _change -> {:ok, attrdiff} end
        )

      {:ok, refreshed} = Change.get_by_number(9002)
      assert refreshed.processing_status == :too_large
      assert refreshed.package_count == 1001

      link_count =
        Tracker.Repo.one(
          from(cp in ChangePackage, where: cp.change_id == ^change.id, select: count(cp.id))
        )

      assert link_count == 0
    end

    test "exactly 1000 entries is under cap (inclusive)", %{rate_limit_table: table} do
      change = insert_change!(number: 9003, state: :merged, merge_commit_sha: "exactsha")
      at_cap = for i <- 1..1000, do: "pkg-#{i}"
      attrdiff = %{"added" => at_cap, "changed" => [], "removed" => []}

      :ok =
        ChangeArtifactRefreshWorker.run(
          %{reason: "merged", number: 9003},
          rate_limit_table: table,
          attrdiff_fetcher: fn _change -> {:ok, attrdiff} end
        )

      {:ok, refreshed} = Change.get_by_number(9003)
      assert refreshed.processing_status == :processed
      assert refreshed.package_count == 1000

      link_count =
        Tracker.Repo.one(
          from(cp in ChangePackage, where: cp.change_id == ^change.id, select: count(cp.id))
        )

      assert link_count == 1000
    end

    test "fetcher returning :snooze propagates {:snooze, n}", %{rate_limit_table: table} do
      insert_change!(number: 9004, state: :merged, merge_commit_sha: "snoozesha")

      assert {:snooze, 120} =
               ChangeArtifactRefreshWorker.run(
                 %{reason: "merged", number: 9004},
                 rate_limit_table: table,
                 attrdiff_fetcher: fn _ -> {:snooze, 120} end
               )
    end

    test "terminal errors set matching status and return :ok without retry", %{
      rate_limit_table: table
    } do
      for {reason, number} <- [
            {:artifact_expired, 9005},
            {:no_workflow_run, 9015},
            {:no_comparison_artifact, 9025}
          ] do
        insert_change!(number: number, state: :merged, merge_commit_sha: "sha#{number}")

        :ok =
          ChangeArtifactRefreshWorker.run(
            %{reason: "merged", number: number},
            rate_limit_table: table,
            attrdiff_fetcher: fn _ -> {:error, reason} end
          )

        {:ok, refreshed} = Change.get_by_number(number)
        assert refreshed.processing_status == reason
      end
    end

    test "fetcher generic error sets :failed and returns {:error, reason}", %{
      rate_limit_table: table
    } do
      insert_change!(number: 9006, state: :merged, merge_commit_sha: "errsha")

      assert {:error, :something} =
               ChangeArtifactRefreshWorker.run(
                 %{reason: "merged", number: 9006},
                 rate_limit_table: table,
                 attrdiff_fetcher: fn _ -> {:error, :something} end
               )

      {:ok, refreshed} = Change.get_by_number(9006)
      assert refreshed.processing_status == :failed
    end

    test "REST rate-limit cache short-circuits with snooze", %{rate_limit_table: table} do
      RateLimitCache.set_reset(:rest, System.os_time(:second) + 60, table)

      assert {:snooze, seconds} =
               ChangeArtifactRefreshWorker.run(
                 %{reason: "merged", number: 9007},
                 rate_limit_table: table,
                 attrdiff_fetcher: fn _ -> raise "fetcher should not be called" end
               )

      assert seconds > 0
    end

    test "unknown Change number: logs and returns :ok", %{rate_limit_table: table} do
      assert :ok =
               ChangeArtifactRefreshWorker.run(
                 %{reason: "merged", number: 999_999_999},
                 rate_limit_table: table,
                 attrdiff_fetcher: fn _ -> raise "fetcher should not be called" end
               )
    end

    test "dedupes packages appearing in multiple attrdiff buckets", %{rate_limit_table: table} do
      change = insert_change!(number: 9009, state: :merged, merge_commit_sha: "dupesha")

      attrdiff = %{
        "added" => ["pkg-only-added"],
        "changed" => ["pkg-multi"],
        "removed" => ["pkg-multi"]
      }

      :ok =
        ChangeArtifactRefreshWorker.run(
          %{reason: "merged", number: 9009},
          rate_limit_table: table,
          attrdiff_fetcher: fn _ -> {:ok, attrdiff} end
        )

      {:ok, refreshed} = Change.get_by_number(9009)
      assert refreshed.processing_status == :processed

      links =
        Tracker.Repo.all(
          from cp in ChangePackage,
            join: p in Package,
            on: p.id == cp.package_id,
            where: cp.change_id == ^change.id,
            select: {p.attribute, cp.type}
        )

      assert Enum.sort(links) == [{"pkg-multi", :changed}, {"pkg-only-added", :added}]
      assert refreshed.package_count == 2
    end

    test "ignored packages are filtered out of the link set", %{rate_limit_table: table} do
      change = insert_change!(number: 9008, state: :merged, merge_commit_sha: "ignsha")

      attrdiff = %{
        "added" => ["nixos-install-tools", "real-pkg"],
        "changed" => [],
        "removed" => ["tests.nixos-functions.nixos-test"]
      }

      :ok =
        ChangeArtifactRefreshWorker.run(
          %{reason: "merged", number: 9008},
          rate_limit_table: table,
          attrdiff_fetcher: fn _ -> {:ok, attrdiff} end
        )

      {:ok, refreshed} = Change.get_by_number(9008)
      assert refreshed.package_count == 1

      link_count =
        Tracker.Repo.one(
          from(cp in ChangePackage, where: cp.change_id == ^change.id, select: count(cp.id))
        )

      assert link_count == 1
    end
  end

  describe "run/2 with reason=head_sha_changed" do
    test "replaces link set, updates status to :processed, bumps package_count", %{
      rate_limit_table: table
    } do
      change = insert_change!(number: 9200, state: :open, head_sha: "newsha")

      stale_pkg = insert_package!("legacy-open-pkg")
      insert_change_package!(change.id, stale_pkg.id, :changed)

      attrdiff = %{"added" => ["open-pkg-a"], "changed" => ["open-pkg-b"], "removed" => []}

      :ok =
        ChangeArtifactRefreshWorker.run(
          %{reason: "head_sha_changed", number: 9200},
          rate_limit_table: table,
          attrdiff_fetcher: fn _change -> {:ok, attrdiff} end
        )

      {:ok, refreshed} = Change.get_by_number(9200)
      assert refreshed.processing_status == :processed
      assert refreshed.package_count == 2

      links =
        Tracker.Repo.all(
          from cp in ChangePackage,
            join: p in Package,
            on: p.id == cp.package_id,
            where: cp.change_id == ^change.id,
            select: {p.attribute, cp.type}
        )

      assert Enum.sort(links) == [{"open-pkg-a", :added}, {"open-pkg-b", :changed}]
    end

    test "cap enforcement: over 1000 entries writes zero rows, status :too_large", %{
      rate_limit_table: table
    } do
      change = insert_change!(number: 9201, state: :draft, head_sha: "bigopen")
      over_cap = for i <- 1..1001, do: "open-pkg-#{i}"
      attrdiff = %{"added" => over_cap, "changed" => [], "removed" => []}

      :ok =
        ChangeArtifactRefreshWorker.run(
          %{reason: "head_sha_changed", number: 9201},
          rate_limit_table: table,
          attrdiff_fetcher: fn _ -> {:ok, attrdiff} end
        )

      {:ok, refreshed} = Change.get_by_number(9201)
      assert refreshed.processing_status == :too_large
      assert refreshed.package_count == 1001

      link_count =
        Tracker.Repo.one(
          from(cp in ChangePackage, where: cp.change_id == ^change.id, select: count(cp.id))
        )

      assert link_count == 0
    end

    test "fetcher returning :snooze propagates {:snooze, n}", %{rate_limit_table: table} do
      insert_change!(number: 9202, state: :open, head_sha: "snoozeopen")

      assert {:snooze, 90} =
               ChangeArtifactRefreshWorker.run(
                 %{reason: "head_sha_changed", number: 9202},
                 rate_limit_table: table,
                 attrdiff_fetcher: fn _ -> {:snooze, 90} end
               )
    end

    test "terminal errors set matching status and return :ok without retry", %{
      rate_limit_table: table
    } do
      for {reason, number} <- [
            {:artifact_expired, 9203},
            {:no_workflow_run, 9213},
            {:no_comparison_artifact, 9223}
          ] do
        insert_change!(number: number, state: :open, head_sha: "sha#{number}")

        :ok =
          ChangeArtifactRefreshWorker.run(
            %{reason: "head_sha_changed", number: number},
            rate_limit_table: table,
            attrdiff_fetcher: fn _ -> {:error, reason} end
          )

        {:ok, refreshed} = Change.get_by_number(number)
        assert refreshed.processing_status == reason
      end
    end

    test "fetcher generic error sets :failed and returns {:error, reason}", %{
      rate_limit_table: table
    } do
      insert_change!(number: 9204, state: :open, head_sha: "erropen")

      assert {:error, :boom} =
               ChangeArtifactRefreshWorker.run(
                 %{reason: "head_sha_changed", number: 9204},
                 rate_limit_table: table,
                 attrdiff_fetcher: fn _ -> {:error, :boom} end
               )

      {:ok, refreshed} = Change.get_by_number(9204)
      assert refreshed.processing_status == :failed
    end

    test "REST rate-limit cache short-circuits with snooze", %{rate_limit_table: table} do
      RateLimitCache.set_reset(:rest, System.os_time(:second) + 60, table)

      assert {:snooze, seconds} =
               ChangeArtifactRefreshWorker.run(
                 %{reason: "head_sha_changed", number: 9205},
                 rate_limit_table: table,
                 attrdiff_fetcher: fn _ -> raise "fetcher should not be called" end
               )

      assert seconds > 0
    end

    test "unknown Change number: logs and returns :ok", %{rate_limit_table: table} do
      assert :ok =
               ChangeArtifactRefreshWorker.run(
                 %{reason: "head_sha_changed", number: 999_999_998},
                 rate_limit_table: table,
                 attrdiff_fetcher: fn _ -> raise "fetcher should not be called" end
               )
    end
  end

  describe "run/2 with unknown reason" do
    test "no-ops and returns :ok", %{rate_limit_table: table} do
      insert_change!(number: 9100, state: :open)

      assert :ok =
               ChangeArtifactRefreshWorker.run(
                 %{reason: "something_else", number: 9100},
                 rate_limit_table: table,
                 attrdiff_fetcher: fn _ -> raise "fetcher should not be called" end
               )
    end
  end

  defp insert_change!(attrs) do
    defaults = [
      title: "test PR",
      state: :merged,
      author: "tester",
      url: "https://github.com/NixOS/nixpkgs/pull/#{attrs[:number]}",
      base_ref: "master"
    ]

    record = Keyword.merge(defaults, attrs) |> Map.new()
    Change.bulk_upsert_all([record])
    {:ok, change} = Change.get_by_number(attrs[:number])
    change
  end

  defp insert_package!(attribute) do
    Package.bulk_upsert_all([%{attribute: attribute}])

    require Ash.Query

    Package
    |> Ash.Query.filter(attribute == ^attribute)
    |> Ash.read_one!()
  end

  defp insert_change_package!(change_id, package_id, type) do
    ChangePackage.bulk_create_all([%{change_id: change_id, package_id: package_id, type: type}])
  end
end

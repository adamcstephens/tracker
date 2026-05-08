defmodule Tracker.Nixpkgs.ChangeBranchDetectionWorkerTest do
  use Tracker.DataCase, async: false

  alias Tracker.GitServer
  alias Tracker.Nixpkgs.Change
  alias Tracker.Nixpkgs.ChangeBranch
  alias Tracker.Nixpkgs.ChangeBranchDetectionWorker

  @tmp_root Path.expand("../../../tmp/change_branch_detection_worker_test", __DIR__)

  setup do
    base = Path.join(@tmp_root, "#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)

    upstream_work = Path.join(base, "upstream_work")
    upstream = Path.join(base, "upstream.git")
    local = Path.join(base, "local.git")

    shas = build_upstream(upstream_work, upstream)

    pid =
      start_supervised!({GitServer, name: nil, repo_url: upstream, path: local, auto_start: true})

    assert GitServer.ready?(pid)

    Map.merge(shas, %{git_server: pid, base: base})
  end

  describe "run/1" do
    test "creates ChangeBranch for downstream branches that contain merge_commit_sha", ctx do
      change = insert_change!(base_ref: "master", merge_commit_sha: ctx.sha_mc)

      :ok = ChangeBranchDetectionWorker.run(git_server: ctx.git_server)

      assert recorded_branches(change) == ["nixpkgs-unstable"]
    end

    test "does not duplicate ChangeBranch rows already present", ctx do
      change = insert_change!(base_ref: "master", merge_commit_sha: ctx.sha_mc)

      ChangeBranch.create!(%{
        change_id: change.id,
        branch_name: "nixpkgs-unstable",
        arrived_at: ~U[2026-01-01 00:00:00Z]
      })

      :ok = ChangeBranchDetectionWorker.run(git_server: ctx.git_server)

      [cb] =
        change
        |> Ash.load!(:change_branches)
        |> Map.fetch!(:change_branches)

      assert cb.branch_name == "nixpkgs-unstable"
      assert cb.arrived_at == ~U[2026-01-01 00:00:00Z]
    end

    test "skips Changes whose recorded set covers all terminal channels", ctx do
      change = insert_change!(base_ref: "master", merge_commit_sha: ctx.sha_mc)

      for branch <- ~w(nixpkgs-unstable nixos-unstable-small nixos-unstable) do
        ChangeBranch.create!(%{
          change_id: change.id,
          branch_name: branch,
          arrived_at: ~U[2026-01-01 00:00:00Z]
        })
      end

      :ok = ChangeBranchDetectionWorker.run(git_server: ctx.git_server)

      arrived =
        change
        |> Ash.load!(:change_branches)
        |> Map.fetch!(:change_branches)
        |> Enum.map(& &1.arrived_at)

      assert arrived == [
               ~U[2026-01-01 00:00:00Z],
               ~U[2026-01-01 00:00:00Z],
               ~U[2026-01-01 00:00:00Z]
             ]
    end

    test "ignores Changes with nil merge_commit_sha", ctx do
      change = insert_change!(base_ref: "master", merge_commit_sha: nil)

      :ok = ChangeBranchDetectionWorker.run(git_server: ctx.git_server)

      assert recorded_branches(change) == []
    end

    test "ignores Changes with base_ref outside the propagation graph", ctx do
      change = insert_change!(base_ref: "feature/x", merge_commit_sha: ctx.sha_mc)

      :ok = ChangeBranchDetectionWorker.run(git_server: ctx.git_server)

      assert recorded_branches(change) == []
    end

    test "handles unknown_ref gracefully (logs and continues)", ctx do
      change = insert_change!(base_ref: "release-99.99", merge_commit_sha: ctx.sha_mc)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = ChangeBranchDetectionWorker.run(git_server: ctx.git_server)
        end)

      assert log =~ "ancestor check failed"
      assert recorded_branches(change) == []
    end
  end

  defp insert_change!(attrs) do
    number = System.unique_integer([:positive])

    record =
      Map.merge(
        %{
          number: number,
          title: "PR ##{number}",
          state: :merged,
          author: "tester",
          url: "https://github.com/NixOS/nixpkgs/pull/#{number}",
          merged_at: ~U[2026-04-23 10:00:00Z]
        },
        Map.new(attrs)
      )

    Change.bulk_upsert_all([record])
    Change.get_by_number!(number)
  end

  defp recorded_branches(change) do
    change
    |> Ash.load!(:change_branches)
    |> Map.fetch!(:change_branches)
    |> Enum.map(& &1.branch_name)
    |> Enum.sort()
  end

  # Builds a tiny propagation-shaped repo:
  #
  #   master:               A -- B -- MC -- C
  #   nixpkgs-unstable:                MC          (MC is ancestor)
  #   nixos-unstable-small:       B               (MC is NOT ancestor)
  #   nixos-unstable:        A                    (MC is NOT ancestor)
  #
  # Worker should record only `nixpkgs-unstable` for a change with
  # base_ref="master" and merge_commit_sha=MC.
  defp build_upstream(work, bare) do
    File.mkdir_p!(work)
    git!(work, ["init", "--quiet", "--initial-branch=master"])
    git!(work, ["config", "user.email", "test@example.com"])
    git!(work, ["config", "user.name", "Test"])
    git!(work, ["config", "commit.gpgsign", "false"])

    File.write!(Path.join(work, "a.txt"), "a\n")
    git!(work, ["add", "a.txt"])
    git!(work, ["commit", "--quiet", "--message", "A"])
    sha_a = work |> git!(["rev-parse", "HEAD"]) |> String.trim()

    File.write!(Path.join(work, "b.txt"), "b\n")
    git!(work, ["add", "b.txt"])
    git!(work, ["commit", "--quiet", "--message", "B"])
    sha_b = work |> git!(["rev-parse", "HEAD"]) |> String.trim()

    File.write!(Path.join(work, "mc.txt"), "mc\n")
    git!(work, ["add", "mc.txt"])
    git!(work, ["commit", "--quiet", "--message", "MC"])
    sha_mc = work |> git!(["rev-parse", "HEAD"]) |> String.trim()

    File.write!(Path.join(work, "c.txt"), "c\n")
    git!(work, ["add", "c.txt"])
    git!(work, ["commit", "--quiet", "--message", "C"])

    git!(work, ["branch", "nixpkgs-unstable", sha_mc])
    git!(work, ["branch", "nixos-unstable-small", sha_b])
    git!(work, ["branch", "nixos-unstable", sha_a])

    {_, 0} = System.cmd("git", ["clone", "--quiet", "--bare", work, bare])

    %{sha_a: sha_a, sha_b: sha_b, sha_mc: sha_mc}
  end

  defp git!(cwd, args) do
    case System.cmd("git", ["-C", cwd | args], stderr_to_stdout: true) do
      {out, 0} -> out
      {out, code} -> flunk("git #{Enum.join(args, " ")} exited #{code}: #{out}")
    end
  end
end

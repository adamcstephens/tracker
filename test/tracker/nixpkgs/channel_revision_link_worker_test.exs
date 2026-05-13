defmodule Tracker.Nixpkgs.ChannelRevisionLinkWorkerTest do
  use Tracker.DataCase, async: false

  import ExUnit.CaptureLog

  require Logger

  alias Tracker.GitServer
  alias Tracker.Nixpkgs.Change
  alias Tracker.Nixpkgs.ChangeBranch
  alias Tracker.Nixpkgs.Channel
  alias Tracker.Nixpkgs.ChannelRevision
  alias Tracker.Nixpkgs.ChannelRevisionLinkWorker

  @tmp_root Path.expand("../../../tmp/channel_revision_link_worker_test", __DIR__)

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

    channel = create_channel!("nixos-unstable")

    r1 =
      ChannelRevision.create!(%{
        channel_id: channel.id,
        revision: shas.sha_a,
        released_at: ~U[2026-05-01 00:00:00Z]
      })

    r2 =
      ChannelRevision.create!(%{
        channel_id: channel.id,
        revision: shas.sha_b,
        released_at: ~U[2026-05-02 00:00:00Z],
        previous_channel_revision_id: r1.id
      })

    r3 =
      ChannelRevision.create!(%{
        channel_id: channel.id,
        revision: shas.sha_mc,
        released_at: ~U[2026-05-03 00:00:00Z],
        previous_channel_revision_id: r2.id
      })

    Map.merge(shas, %{
      git_server: pid,
      channel: channel,
      r1: r1,
      r2: r2,
      r3: r3
    })
  end

  describe "run/1" do
    test "links a change to R_n when it first lands in R_n", ctx do
      # Change with sha_b lands in R2 (B and onwards) but not R1 (A).
      change = insert_change!(base_ref: "master", merge_commit_sha: ctx.sha_b)

      :ok =
        ChannelRevisionLinkWorker.run(
          channel_revision_id: ctx.r2.id,
          git_server: ctx.git_server
        )

      [cb] = change_branches_for(change, "nixos-unstable")
      assert cb.channel_revision_id == ctx.r2.id
    end

    test "links to R_n when it is the first revision (no previous)", ctx do
      # Change with sha_a — only ancestor of R1 (sha_a), not R2/R3.
      change = insert_change!(base_ref: "master", merge_commit_sha: ctx.sha_a)

      :ok =
        ChannelRevisionLinkWorker.run(
          channel_revision_id: ctx.r1.id,
          git_server: ctx.git_server
        )

      [cb] = change_branches_for(change, "nixos-unstable")
      assert cb.channel_revision_id == ctx.r1.id
    end

    test "bisects backwards when change was already in a prior revision", ctx do
      # Change with sha_a is an ancestor of R1, R2, R3. Trigger fires for R3
      # before any earlier trigger has recorded the change. Worker must
      # bisect and link to R1.
      change = insert_change!(base_ref: "master", merge_commit_sha: ctx.sha_a)

      :ok =
        ChannelRevisionLinkWorker.run(
          channel_revision_id: ctx.r3.id,
          git_server: ctx.git_server
        )

      [cb] = change_branches_for(change, "nixos-unstable")
      assert cb.channel_revision_id == ctx.r1.id
    end

    test "fills channel_revision_id on a legacy nil row", ctx do
      change = insert_change!(base_ref: "master", merge_commit_sha: ctx.sha_b)

      ChangeBranch.create!(%{change_id: change.id, branch_name: "nixos-unstable"})

      :ok =
        ChannelRevisionLinkWorker.run(
          channel_revision_id: ctx.r2.id,
          git_server: ctx.git_server
        )

      [cb] = change_branches_for(change, "nixos-unstable")
      assert cb.channel_revision_id == ctx.r2.id
    end

    test "skips changes already linked for this branch", ctx do
      change = insert_change!(base_ref: "master", merge_commit_sha: ctx.sha_b)

      ChangeBranch.create!(%{
        change_id: change.id,
        branch_name: "nixos-unstable",
        channel_revision_id: ctx.r2.id
      })

      :ok =
        ChannelRevisionLinkWorker.run(
          channel_revision_id: ctx.r3.id,
          git_server: ctx.git_server
        )

      [cb] = change_branches_for(change, "nixos-unstable")
      # unchanged — still points at R2
      assert cb.channel_revision_id == ctx.r2.id
    end

    test "skips changes whose sha is not an ancestor of R_n", ctx do
      # sha_mc is in R3 only. Triggering R2 (sha_b) — sha_mc is NOT ancestor.
      change = insert_change!(base_ref: "master", merge_commit_sha: ctx.sha_mc)

      :ok =
        ChannelRevisionLinkWorker.run(
          channel_revision_id: ctx.r2.id,
          git_server: ctx.git_server
        )

      assert change_branches_for(change, "nixos-unstable") == []
    end

    test "ignores changes with nil merge_commit_sha", ctx do
      change = insert_change!(base_ref: "master", merge_commit_sha: nil)

      :ok =
        ChannelRevisionLinkWorker.run(
          channel_revision_id: ctx.r2.id,
          git_server: ctx.git_server
        )

      assert change_branches_for(change, "nixos-unstable") == []
    end

    test "emits structured start/stop logs", ctx do
      insert_change!(base_ref: "master", merge_commit_sha: ctx.sha_b)
      Logger.put_module_level(ChannelRevisionLinkWorker, :info)
      on_exit(fn -> Logger.delete_module_level(ChannelRevisionLinkWorker) end)

      log =
        capture_log(fn ->
          assert :ok =
                   ChannelRevisionLinkWorker.run(
                     channel_revision_id: ctx.r2.id,
                     git_server: ctx.git_server
                   )
        end)

      assert log =~ ~s(msg: "channel revision link started")
      assert log =~ ~s(msg: "channel revision link finished")
      assert log =~ "outcome: :ok"
      assert log =~ "branch_name: \"nixos-unstable\""
      assert log =~ ~r/candidates: \d+/
      assert log =~ ~r/recorded: [1-9]\d*/
      assert log =~ ~r/duration_ms: \d+/
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

  defp create_channel!(name) do
    Channel.create!(%{
      name: name,
      display_name: name,
      status: :active,
      is_stable: false
    })
  end

  defp change_branches_for(change, branch_name) do
    change
    |> Ash.load!(:change_branches)
    |> Map.fetch!(:change_branches)
    |> Enum.filter(&(&1.branch_name == branch_name))
  end

  # Linear chain: A -- B -- MC -- C, with channel-revision shas pointing
  # at A, B, MC. Branch `master` is at MC so propagation-graph candidates
  # exist for changes with base_ref="master".
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

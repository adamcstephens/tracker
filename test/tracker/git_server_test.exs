defmodule Tracker.GitServerTest do
  use ExUnit.Case, async: true

  alias Tracker.GitServer

  @tmp_root Path.expand("../../tmp/git_server_test", __DIR__)

  setup do
    base = Path.join(@tmp_root, "#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)

    upstream_work = Path.join(base, "upstream_work")
    upstream = Path.join(base, "upstream.git")
    local = Path.join(base, "local.git")

    {sha_one, sha_two, sha_side} = build_upstream(upstream_work, upstream)

    %{
      base: base,
      upstream: upstream,
      local: local,
      sha_one: sha_one,
      sha_two: sha_two,
      sha_side: sha_side
    }
  end

  describe "auto_start: false" do
    test "starts in :not_ready and rejects calls", %{upstream: upstream, local: local} do
      pid =
        start_supervised!(
          {GitServer, name: nil, repo_url: upstream, path: local, auto_start: false}
        )

      refute GitServer.ready?(pid)
      assert GitServer.ancestor?(pid, "deadbeef", "refs/heads/main") == {:error, :not_ready}
      assert GitServer.fetch(pid) == {:error, :not_ready}

      refute File.exists?(local), "should not clone when auto_start is false"
    end
  end

  describe "clone-on-boot" do
    test "clones a missing repo and becomes ready", %{upstream: upstream, local: local} do
      pid =
        start_supervised!(
          {GitServer, name: nil, repo_url: upstream, path: local, auto_start: true}
        )

      assert GitServer.ready?(pid)
      assert File.dir?(local)
      assert {git_dir, 0} = System.cmd("git", ["-C", local, "rev-parse", "--git-dir"])
      assert String.trim(git_dir) == "."
    end

    test "reuses an existing valid bare repo without recloning", %{
      upstream: upstream,
      local: local
    } do
      {_, 0} = System.cmd("git", ["clone", "--bare", upstream, local])
      mtime_before = File.stat!(Path.join(local, "HEAD")).mtime

      pid =
        start_supervised!(
          {GitServer, name: nil, repo_url: upstream, path: local, auto_start: true}
        )

      assert GitServer.ready?(pid)
      assert File.stat!(Path.join(local, "HEAD")).mtime == mtime_before
    end

    test "stays :not_ready when path exists but is not a git dir", %{local: local} = ctx do
      File.mkdir_p!(local)
      File.write!(Path.join(local, "garbage.txt"), "not a repo")

      pid =
        start_supervised!(
          {GitServer, name: nil, repo_url: ctx.upstream, path: local, auto_start: true}
        )

      refute GitServer.ready?(pid)
      assert GitServer.ancestor?(pid, "deadbeef", "refs/heads/main") == {:error, :not_ready}
    end

    test "configures a narrow fetch refspec scoped to refs/heads/*", %{
      upstream: upstream,
      local: local
    } do
      pid =
        start_supervised!(
          {GitServer, name: nil, repo_url: upstream, path: local, auto_start: true}
        )

      assert GitServer.ready?(pid)

      {fetch, 0} =
        System.cmd("git", ["-C", local, "config", "--get-all", "remote.origin.fetch"])

      assert String.trim(fetch) == "+refs/heads/*:refs/heads/*"

      {tagopt, 0} =
        System.cmd("git", ["-C", local, "config", "--get-all", "remote.origin.tagOpt"])

      assert String.trim(tagopt) == "--no-tags"
    end

    test "stays :not_ready when path is a half-cloned mirror with no refs",
         %{local: local} = ctx do
      File.mkdir_p!(local)
      {_, 0} = System.cmd("git", ["-C", local, "init", "--quiet", "--bare"])

      pid =
        start_supervised!(
          {GitServer, name: nil, repo_url: ctx.upstream, path: local, auto_start: true}
        )

      refute GitServer.ready?(pid)
    end
  end

  describe "ancestor?/3" do
    setup ctx do
      pid =
        start_supervised!(
          {GitServer, name: nil, repo_url: ctx.upstream, path: ctx.local, auto_start: true}
        )

      assert GitServer.ready?(pid)
      %{pid: pid}
    end

    test "true for an ancestor of the ref", %{pid: pid, sha_one: sha_one} do
      assert GitServer.ancestor?(pid, sha_one, "refs/heads/main") == {:ok, true}
    end

    test "true when sha equals the ref tip", %{pid: pid, sha_two: sha_two} do
      assert GitServer.ancestor?(pid, sha_two, "refs/heads/main") == {:ok, true}
    end

    test "false for a sha on an unmerged side branch", %{pid: pid, sha_side: sha_side} do
      assert GitServer.ancestor?(pid, sha_side, "refs/heads/main") == {:ok, false}
    end

    test ":unknown_sha for a sha that isn't in the local clone", %{pid: pid} do
      missing = String.duplicate("0", 40)
      assert GitServer.ancestor?(pid, missing, "refs/heads/main") == {:error, :unknown_sha}
    end

    test ":unknown_ref for a ref that doesn't exist locally", %{pid: pid, sha_one: sha_one} do
      assert GitServer.ancestor?(pid, sha_one, "refs/heads/does-not-exist") ==
               {:error, :unknown_ref}
    end
  end

  describe "fetch/1" do
    test "picks up new commits from the remote", %{
      base: base,
      upstream: upstream,
      local: local
    } do
      pid =
        start_supervised!(
          {GitServer, name: nil, repo_url: upstream, path: local, auto_start: true}
        )

      assert GitServer.ready?(pid)

      new_sha = add_upstream_commit(Path.join(base, "upstream_work"), upstream)

      assert GitServer.ancestor?(pid, new_sha, "refs/heads/main") == {:error, :unknown_sha}
      assert GitServer.fetch(pid) == :ok
      assert GitServer.ancestor?(pid, new_sha, "refs/heads/main") == {:ok, true}
    end
  end

  defp build_upstream(work, bare) do
    File.mkdir_p!(work)
    git!(work, ["init", "--quiet", "--initial-branch=main"])
    git!(work, ["config", "user.email", "test@example.com"])
    git!(work, ["config", "user.name", "Test"])
    git!(work, ["config", "commit.gpgsign", "false"])

    File.write!(Path.join(work, "a.txt"), "one\n")
    git!(work, ["add", "a.txt"])
    git!(work, ["commit", "--quiet", "--message", "one"])
    sha_one = work |> git!(["rev-parse", "HEAD"]) |> String.trim()

    File.write!(Path.join(work, "b.txt"), "two\n")
    git!(work, ["add", "b.txt"])
    git!(work, ["commit", "--quiet", "--message", "two"])
    sha_two = work |> git!(["rev-parse", "HEAD"]) |> String.trim()

    git!(work, ["checkout", "--quiet", "-b", "side", sha_one])
    File.write!(Path.join(work, "side.txt"), "side\n")
    git!(work, ["add", "side.txt"])
    git!(work, ["commit", "--quiet", "--message", "side"])
    sha_side = work |> git!(["rev-parse", "HEAD"]) |> String.trim()
    git!(work, ["checkout", "--quiet", "main"])

    {_, 0} = System.cmd("git", ["clone", "--quiet", "--bare", work, bare])
    {sha_one, sha_two, sha_side}
  end

  defp add_upstream_commit(work, bare) do
    File.write!(Path.join(work, "c.txt"), "three\n")
    git!(work, ["add", "c.txt"])
    git!(work, ["commit", "--quiet", "--message", "three"])
    sha = work |> git!(["rev-parse", "HEAD"]) |> String.trim()
    {_, 0} = System.cmd("git", ["-C", bare, "fetch", "--quiet", work, "main:main"])
    sha
  end

  defp git!(cwd, args) do
    case System.cmd("git", ["-C", cwd | args], stderr_to_stdout: true) do
      {out, 0} -> out
      {out, code} -> flunk("git #{Enum.join(args, " ")} exited #{code}: #{out}")
    end
  end
end

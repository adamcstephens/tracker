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

      assert GitServer.ancestor?("deadbeef", "refs/heads/main", GitServer.state(pid)) ==
               {:error, :not_ready}

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

      assert GitServer.ancestor?("deadbeef", "refs/heads/main", GitServer.state(pid)) ==
               {:error, :not_ready}
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

    test "enables commit-graph configs", %{upstream: upstream, local: local} do
      pid =
        start_supervised!(
          {GitServer, name: nil, repo_url: upstream, path: local, auto_start: true}
        )

      assert GitServer.ready?(pid)

      assert git_config(local, "core.commitGraph") == "true"
      assert git_config(local, "gc.writeCommitGraph") == "false"
    end

    test "writes a commit-graph after cloning", %{upstream: upstream, local: local} do
      pid =
        start_supervised!(
          {GitServer, name: nil, repo_url: upstream, path: local, auto_start: true}
        )

      assert GitServer.ready?(pid)
      assert commit_graph_present?(local)
    end

    test "writes a commit-graph when reusing an existing valid bare repo", %{
      upstream: upstream,
      local: local
    } do
      {_, 0} = System.cmd("git", ["clone", "--bare", "--quiet", upstream, local])
      refute commit_graph_present?(local)

      pid =
        start_supervised!(
          {GitServer, name: nil, repo_url: upstream, path: local, auto_start: true}
        )

      assert GitServer.ready?(pid)
      assert commit_graph_present?(local)
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
      %{state: GitServer.state(pid)}
    end

    test "true for an ancestor of the ref", %{state: state, sha_one: sha_one} do
      assert GitServer.ancestor?(sha_one, "refs/heads/main", state) == {:ok, true}
    end

    test "true when sha equals the ref tip", %{state: state, sha_two: sha_two} do
      assert GitServer.ancestor?(sha_two, "refs/heads/main", state) == {:ok, true}
    end

    test "false for a sha on an unmerged side branch", %{state: state, sha_side: sha_side} do
      assert GitServer.ancestor?(sha_side, "refs/heads/main", state) == {:ok, false}
    end

    test ":unknown_sha for a sha that isn't in the local clone", %{state: state} do
      missing = String.duplicate("0", 40)
      assert GitServer.ancestor?(missing, "refs/heads/main", state) == {:error, :unknown_sha}
    end

    test ":unknown_ref for a ref that doesn't exist locally", %{state: state, sha_one: sha_one} do
      assert GitServer.ancestor?(sha_one, "refs/heads/does-not-exist", state) ==
               {:error, :unknown_ref}
    end
  end

  describe "ancestors?/3" do
    setup ctx do
      pid =
        start_supervised!(
          {GitServer, name: nil, repo_url: ctx.upstream, path: ctx.local, auto_start: true}
        )

      assert GitServer.ready?(pid)
      %{state: GitServer.state(pid)}
    end

    test "returns a result per ref", %{state: state, sha_one: sha_one} do
      results =
        GitServer.ancestors?(
          sha_one,
          ["refs/heads/main", "refs/heads/side", "refs/heads/does-not-exist"],
          state
        )

      assert results == %{
               "refs/heads/main" => {:ok, true},
               "refs/heads/side" => {:ok, true},
               "refs/heads/does-not-exist" => {:error, :unknown_ref}
             }
    end

    test "uniformly returns :not_ready against a not-ready snapshot", ctx do
      not_ready_local = Path.join(ctx.base, "not_ready.git")

      pid =
        start_supervised!(
          Supervisor.child_spec(
            {GitServer,
             name: nil, repo_url: ctx.upstream, path: not_ready_local, auto_start: false},
            id: :not_ready_gitserver
          )
        )

      results =
        GitServer.ancestors?(
          "deadbeef",
          ["refs/heads/main", "refs/heads/other"],
          GitServer.state(pid)
        )

      assert results == %{
               "refs/heads/main" => {:error, :not_ready},
               "refs/heads/other" => {:error, :not_ready}
             }
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

      assert GitServer.ancestor?(new_sha, "refs/heads/main", GitServer.state(pid)) ==
               {:error, :unknown_sha}

      assert GitServer.fetch(pid) == :ok

      assert GitServer.ancestor?(new_sha, "refs/heads/main", GitServer.state(pid)) ==
               {:ok, true}
    end

    test "refreshes commit-graph after fetch", %{
      base: base,
      upstream: upstream,
      local: local
    } do
      pid =
        start_supervised!(
          {GitServer, name: nil, repo_url: upstream, path: local, auto_start: true}
        )

      assert GitServer.ready?(pid)
      graph_before = commit_graph_fingerprint(local)
      assert graph_before != nil

      # Wait long enough that any new graph file has a strictly later mtime,
      # since File.stat/1 mtime resolution is one second.
      :timer.sleep(1100)

      _new_sha = add_upstream_commit(Path.join(base, "upstream_work"), upstream)
      assert GitServer.fetch(pid) == :ok

      graph_after = commit_graph_fingerprint(local)
      assert graph_after != nil
      assert graph_after != graph_before
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

  defp git_config(repo, key) do
    {out, 0} = System.cmd("git", ["-C", repo, "config", "--get", key])
    String.trim(out)
  end

  defp commit_graph_present?(repo) do
    File.exists?(Path.join(repo, "objects/info/commit-graph")) or
      File.dir?(Path.join(repo, "objects/info/commit-graphs"))
  end

  defp commit_graph_fingerprint(repo) do
    info = Path.join(repo, "objects/info")
    single = Path.join(info, "commit-graph")
    chain_dir = Path.join(info, "commit-graphs")

    cond do
      File.exists?(single) ->
        stat = File.stat!(single, time: :posix)
        {single, stat.mtime, stat.size}

      File.dir?(chain_dir) ->
        chain_dir
        |> File.ls!()
        |> Enum.sort()
        |> Enum.map(fn name ->
          path = Path.join(chain_dir, name)
          stat = File.stat!(path, time: :posix)
          {name, stat.mtime, stat.size}
        end)

      true ->
        nil
    end
  end
end

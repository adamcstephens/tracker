defmodule Tracker.GitServer do
  @moduledoc """
  Owns a local git clone of an upstream repository.

  Clones on boot (asynchronously, via `handle_continue/2`) and serializes
  long-running mutations (`fetch/1`) through the GenServer.

  Generic over `repo_url` and `path`; one named instance is started under
  the application supervisor for nixpkgs.

  ## Reads bypass the GenServer

  Read operations like `ancestor?/3` take a `State` snapshot directly —
  they shell out to git, which handles concurrent readers natively, and
  routing them through the GenServer would needlessly serialize them
  behind any in-flight `fetch`. Snapshot once with `state/1` and reuse
  it. A snapshot taken before a fetch will see pre-fetch refs for the
  rest of its lifetime; for ingestion that gives a consistent view of
  the world for the duration of a run.

  Mutating calls made before the repo is ready return
  `{:error, :not_ready}`; reads against a not-ready snapshot do the
  same.
  """

  use GenServer

  use TypedStruct

  require Logger

  typedstruct module: State do
    field :repo_url, String.t(), enforce: true
    field :path, String.t(), enforce: true
    field :ready, boolean(), default: false
  end

  # Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc """
  Returns true once the repo has been cloned (or validated) and is ready
  for queries.
  """
  @spec ready?(GenServer.server()) :: boolean()
  def ready?(server \\ __MODULE__) do
    GenServer.call(server, :ready?, :infinity)
  end

  @doc """
  Runs `git fetch --prune` against the configured remote.
  """
  @spec fetch(GenServer.server()) :: :ok | {:error, :not_ready | term()}
  def fetch(server \\ __MODULE__) do
    GenServer.call(server, :fetch, :infinity)
  end

  @doc """
  Returns a `State` snapshot suitable for passing to `ancestor?/3` and
  `ancestors?/3`. Re-fetch after a `fetch/1` if you want the new refs.
  """
  @spec state(GenServer.server()) :: State.t()
  def state(server \\ __MODULE__) do
    GenServer.call(server, :state, :infinity)
  end

  @doc """
  Returns whether `sha` is an ancestor of (or equal to) `ref` in the
  local clone. Does not fetch — call `fetch/1` first if freshness
  matters.

  Bypasses the GenServer: pass a snapshot from `state/1`. Safe to call
  concurrently from many processes.
  """
  @spec ancestor?(String.t(), String.t(), State.t()) ::
          {:ok, boolean()}
          | {:error, :not_ready | :unknown_sha | :unknown_ref | term()}
  def ancestor?(_sha, _ref, %State{ready: false}), do: {:error, :not_ready}

  def ancestor?(sha, ref, %State{path: path}) do
    case run_git(path, ["merge-base", "--is-ancestor", sha, ref]) do
      {_, 0} ->
        {:ok, true}

      {_, 1} ->
        {:ok, false}

      {output, _code} ->
        trimmed = String.trim(output)

        cond do
          String.contains?(trimmed, "Not a valid commit name") ->
            {:error, :unknown_sha}

          String.contains?(trimmed, "unknown revision") or
              String.contains?(trimmed, "Not a valid object name") ->
            {:error, :unknown_ref}

          true ->
            {:error, {:git_failed, trimmed}}
        end
    end
  end

  @doc """
  Returns ancestor results for `sha` against many `refs`, as a map keyed
  by ref. Each value matches `ancestor?/3`'s return shape.

  Sequential by design: callers fanning out across many shas should
  parallelize at the sha level (`Task.async_stream`), reusing the same
  snapshot.
  """
  @spec ancestors?(String.t(), [String.t()], State.t()) ::
          %{
            String.t() =>
              {:ok, boolean()}
              | {:error, :not_ready | :unknown_sha | :unknown_ref | term()}
          }
  def ancestors?(sha, refs, %State{} = state) do
    Map.new(refs, fn ref -> {ref, ancestor?(sha, ref, state)} end)
  end

  # GenServer callbacks

  @impl GenServer
  def init(opts) do
    state = %State{
      repo_url: Keyword.fetch!(opts, :repo_url),
      path: Keyword.fetch!(opts, :path)
    }

    if Keyword.get(opts, :auto_start, true) do
      {:ok, state, {:continue, :ensure_repo}}
    else
      {:ok, state}
    end
  end

  @impl GenServer
  def handle_continue(:ensure_repo, %State{} = state) do
    {:noreply, ensure_repo(state)}
  end

  @impl GenServer
  def handle_call(:ready?, _from, %State{} = state) do
    {:reply, state.ready, state}
  end

  def handle_call(:state, _from, %State{} = state) do
    {:reply, state, state}
  end

  def handle_call(_, _from, %State{ready: false} = state) do
    {:reply, {:error, :not_ready}, state}
  end

  def handle_call(:fetch, _from, %State{} = state) do
    case run_git(state.path, ["fetch", "--prune", "origin"]) do
      {_, 0} ->
        {:reply, :ok, write_commit_graph(state)}

      {output, code} ->
        {:reply, {:error, {:fetch_failed, code, String.trim(output)}}, state}
    end
  end

  # Internal

  # We mirror only refs/heads/* — nixpkgs has ~480k refs/pull/* refs that
  # would otherwise dominate every fetch's negotiation cost.
  @fetch_refspec "+refs/heads/*:refs/heads/*"

  defp ensure_repo(%State{path: path} = state) do
    cond do
      not File.exists?(path) ->
        with %State{ready: true} = state <- clone(state) do
          state |> configure_remote() |> write_commit_graph()
        end

      healthy_repo?(path) ->
        Logger.info("GitServer: reusing existing repo at #{path}")

        %State{state | ready: true}
        |> configure_remote()
        |> write_commit_graph()

      true ->
        Logger.error(
          "GitServer: #{path} exists but is not a healthy git repo; refusing to clone over it"
        )

        state
    end
  end

  defp clone(%State{repo_url: url, path: path} = state) do
    Logger.info("GitServer: cloning #{url} into #{path}")
    File.mkdir_p!(Path.dirname(path))

    args = ["clone", "--bare", "--quiet", "--no-tags", url, path]

    case System.cmd("git", args, stderr_to_stdout: true) do
      {_, 0} ->
        Logger.info("GitServer: clone complete")
        %State{state | ready: true}

      {output, code} ->
        Logger.error("GitServer: clone failed (#{code}): #{String.trim(output)}")
        state
    end
  end

  defp configure_remote(%State{path: path} = state) do
    {_, 0} =
      System.cmd("git", ["-C", path, "config", "remote.origin.fetch", @fetch_refspec],
        stderr_to_stdout: true
      )

    {_, 0} =
      System.cmd("git", ["-C", path, "config", "remote.origin.tagOpt", "--no-tags"],
        stderr_to_stdout: true
      )

    {_, 0} =
      System.cmd("git", ["-C", path, "config", "core.commitGraph", "true"],
        stderr_to_stdout: true
      )

    # We write the commit-graph explicitly via write_commit_graph/1 at known
    # serialized points (post-clone, startup, post-fetch). Letting gc also
    # write it races with us for objects/info/commit-graph.lock.
    {_, 0} =
      System.cmd("git", ["-C", path, "config", "gc.writeCommitGraph", "false"],
        stderr_to_stdout: true
      )

    state
  end

  # Writing the commit-graph keeps `git merge-base --is-ancestor` from
  # walking and inflating commits out of the pack on every query. With
  # ~800k commits in nixpkgs, the difference is roughly 1–5s vs tens of
  # ms on the "not an ancestor" path.
  defp write_commit_graph(%State{path: path} = state) do
    case run_git(path, ["commit-graph", "write", "--reachable", "--changed-paths"]) do
      {_, 0} ->
        state

      {output, code} ->
        Logger.warning(
          "GitServer: commit-graph write failed (#{code}) at #{path}: #{String.trim(output)}"
        )

        state
    end
  end

  defp healthy_repo?(path) do
    valid_git_dir?(path) and has_refs?(path)
  end

  defp valid_git_dir?(path) do
    expanded = Path.expand(path)

    case System.cmd("git", ["-C", path, "rev-parse", "--absolute-git-dir"],
           stderr_to_stdout: true
         ) do
      {output, 0} -> Path.expand(String.trim(output)) == expanded
      _ -> false
    end
  end

  defp has_refs?(path) do
    case System.cmd("git", ["-C", path, "for-each-ref", "--count=1"], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output) != ""
      _ -> false
    end
  end

  defp run_git(path, args) do
    System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
  end
end

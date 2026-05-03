defmodule Tracker.GitServer do
  @moduledoc """
  Owns a local git clone of an upstream repository.

  Clones on boot (asynchronously, via `handle_continue/2`), serializes
  subsequent git invocations through a single GenServer, and exposes a
  narrow Elixir-ergonomic API for the operations we actually need.

  Generic over `repo_url` and `path`; one named instance is started under
  the application supervisor for nixpkgs.

  Calls made before the repo is ready return `{:error, :not_ready}`.
  Long-running operations (`fetch/1`) hold the GenServer for their
  duration — read-throughput limits during a fetch are an accepted
  tradeoff for first cut.
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
  Returns whether `sha` is an ancestor of (or equal to) `ref` in the local
  clone. Does not fetch — call `fetch/1` first if freshness matters.
  """
  @spec ancestor?(GenServer.server(), String.t(), String.t()) ::
          {:ok, boolean()} | {:error, :not_ready | term()}
  def ancestor?(server \\ __MODULE__, sha, ref) do
    GenServer.call(server, {:ancestor?, sha, ref}, :infinity)
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

  def handle_call(_, _from, %State{ready: false} = state) do
    {:reply, {:error, :not_ready}, state}
  end

  def handle_call(:fetch, _from, %State{} = state) do
    case run_git(state.path, ["fetch", "--prune", "origin"]) do
      {_, 0} ->
        {:reply, :ok, state}

      {output, code} ->
        {:reply, {:error, {:fetch_failed, code, String.trim(output)}}, state}
    end
  end

  def handle_call({:ancestor?, sha, ref}, _from, %State{} = state) do
    case run_git(state.path, ["merge-base", "--is-ancestor", sha, ref]) do
      {_, 0} ->
        {:reply, {:ok, true}, state}

      {_, 1} ->
        {:reply, {:ok, false}, state}

      {output, _code} ->
        trimmed = String.trim(output)

        cond do
          String.contains?(trimmed, "Not a valid commit name") ->
            {:reply, {:error, :unknown_sha}, state}

          String.contains?(trimmed, "unknown revision") or
              String.contains?(trimmed, "Not a valid object name") ->
            {:reply, {:error, :unknown_ref}, state}

          true ->
            {:reply, {:error, {:git_failed, trimmed}}, state}
        end
    end
  end

  # Internal

  defp ensure_repo(%State{path: path} = state) do
    cond do
      not File.exists?(path) ->
        clone(state)

      valid_git_dir?(path) ->
        Logger.info("GitServer: reusing existing repo at #{path}")
        %State{state | ready: true}

      true ->
        Logger.error(
          "GitServer: #{path} exists but is not a git directory; refusing to clone over it"
        )

        state
    end
  end

  defp clone(%State{repo_url: url, path: path} = state) do
    Logger.info("GitServer: cloning #{url} into #{path}")
    File.mkdir_p!(Path.dirname(path))

    case System.cmd("git", ["clone", "--mirror", "--quiet", url, path], stderr_to_stdout: true) do
      {_, 0} ->
        Logger.info("GitServer: clone complete")
        %State{state | ready: true}

      {output, code} ->
        Logger.error("GitServer: clone failed (#{code}): #{String.trim(output)}")
        state
    end
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

  defp run_git(path, args) do
    System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
  end
end

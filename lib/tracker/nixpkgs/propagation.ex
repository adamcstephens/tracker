defmodule Tracker.Nixpkgs.Propagation do
  @moduledoc """
  Pure encoding of the nixpkgs branch propagation DAG.

  PRs in nixpkgs flow through a series of branches before reaching the
  channels users consume. The master line:

      staging → staging-next → master → nixos-unstable-small → nixos-unstable
                                      → nixpkgs-unstable
      haskell-updates → staging
      staging-nixos → master

  Per active stable release X.Y:

      staging-X.Y → staging-next-X.Y → release-X.Y → nixos-X.Y-small → nixos-X.Y
                                                   → nixpkgs-X.Y-darwin

  The graph is encoded as forward `{regex, replacement}` rules, modeled on
  nixpkgs-tracker's `NEXT_BRANCH_TABLE`. Reverse queries enumerate
  candidates and forward-traverse rather than maintaining a parallel
  reverse table. This module has no DB dependencies.
  """

  @master_seeds ["staging", "haskell-updates", "staging-nixos"]

  defp next_rules do
    [
      {~r/\Astaging\z/, "staging-next"},
      {~r/\Astaging-next\z/, "master"},
      {~r/\Astaging-next-(\d+\.\d+)\z/, "release-\\1"},
      {~r/\Ahaskell-updates\z/, "staging"},
      {~r/\Astaging-nixos\z/, "master"},
      {~r/\Amaster\z/, "nixpkgs-unstable"},
      {~r/\Amaster\z/, "nixos-unstable-small"},
      {~r/\Anixos-(.+)-small\z/, "nixos-\\1"},
      {~r/\Arelease-(\d+\.\d+)\z/, "nixos-\\1-small"},
      {~r/\Arelease-(\d+\.\d+)\z/, "nixpkgs-\\1-darwin"},
      {~r/\Astaging-(\d+\.\d+)\z/, "staging-next-\\1"}
    ]
  end

  @doc """
  Returns the direct successor branches of `name`, or `[]` for unknown or
  terminal branches.
  """
  @spec next_branches(String.t()) :: [String.t()]
  def next_branches(name) do
    for {regex, replacement} <- next_rules(),
        Regex.match?(regex, name),
        do: Regex.replace(regex, name, replacement)
  end

  @doc """
  Returns the transitive set of branches reachable from `name`, excluding
  `name` itself.
  """
  @spec downstream(String.t()) :: [String.t()]
  def downstream(name) do
    name
    |> traverse(MapSet.new())
    |> MapSet.delete(name)
    |> MapSet.to_list()
  end

  defp traverse(name, acc) do
    if MapSet.member?(acc, name) do
      acc
    else
      acc = MapSet.put(acc, name)
      Enum.reduce(next_branches(name), acc, fn neighbor, acc -> traverse(neighbor, acc) end)
    end
  end

  @doc """
  Returns the channel-kind terminal branches reachable from `name`,
  including `name` itself when it's a channel.
  """
  @spec terminal_channels(String.t()) :: [String.t()]
  def terminal_channels(name) do
    [name | downstream(name)]
    |> Enum.filter(&(kind(&1) == :channel))
  end

  @doc """
  Returns the set of branches that propagate into `name`, excluding `name`
  itself.

  Implemented by enumerating candidate ancestors (the static graph plus the
  versioned branches for `name`'s release line, if any) and filtering by
  forward reachability — no separate reverse table.
  """
  @spec ancestors_of(String.t()) :: [String.t()]
  def ancestors_of(name) do
    candidates = static_branches() ++ versioned_candidates(name)

    candidates
    |> Enum.uniq()
    |> Enum.filter(fn candidate -> candidate != name and name in downstream(candidate) end)
  end

  defp versioned_candidates(name) do
    case Regex.run(~r/(\d+\.\d+)/, name) do
      [_, version] -> branches_for_release(version)
      _ -> []
    end
  end

  @doc """
  Classifies a branch name as a `:channel` (terminal ref consumed by users)
  or an intermediate `:branch`.
  """
  @spec kind(String.t()) :: :channel | :branch
  def kind(name) do
    if String.starts_with?(name, ["nixos-", "nixpkgs-"]),
      do: :channel,
      else: :branch
  end

  @doc """
  Lists the static (non-versioned) branches in the propagation graph.

  Derived by forward-traversing from the seed branches that have no
  predecessor in the master line.
  """
  @spec static_branches() :: [String.t()]
  def static_branches do
    @master_seeds
    |> Enum.flat_map(fn seed -> [seed | downstream(seed)] end)
    |> Enum.uniq()
  end

  @doc """
  Lists every versioned branch participating in the propagation flow for
  release `version` (e.g. `"25.11"`).
  """
  @spec branches_for_release(String.t()) :: [String.t()]
  def branches_for_release(version) do
    seed = "staging-#{version}"
    [seed | downstream(seed)]
  end

  @doc """
  Returns true when `name` is a known branch in the propagation graph.

  Accepts any static branch and any versioned branch belonging to a release
  line — version is derived from the name itself, so this needs no channel
  state.
  """
  @spec valid_branch?(String.t()) :: boolean()
  def valid_branch?(name) do
    name in static_branches() or
      case Regex.run(~r/(\d+\.\d+)/, name) do
        [_, version] -> name in branches_for_release(version)
        _ -> false
      end
  end

  defmodule Node do
    @moduledoc false
    use TypedStruct

    typedstruct enforce: true do
      field :name, String.t()
      field :kind, :branch | :channel
      field :level, non_neg_integer()
      field :present, boolean()
    end
  end

  defmodule Edge do
    @moduledoc false
    use TypedStruct

    typedstruct enforce: true do
      field :from, String.t()
      field :to, String.t()
    end
  end

  defmodule Dag do
    @moduledoc false
    use TypedStruct

    typedstruct enforce: true do
      field :nodes, [Tracker.Nixpkgs.Propagation.Node.t()]
      field :edges, [Tracker.Nixpkgs.Propagation.Edge.t()]
    end
  end

  @doc """
  Builds the propagation DAG rooted at `base_ref`, with each node tagged
  `present: true` when its `name` appears in `present_branches`.

  Levels are BFS depths from the root. Edges are restricted to pairs where
  both endpoints are inside the DAG. Returns an empty DAG when `base_ref`
  is nil or not a known branch.
  """
  @spec lifecycle(String.t() | nil, [String.t()]) :: Dag.t()
  def lifecycle(base_ref, present_branches) when is_binary(base_ref) do
    if valid_branch?(base_ref) do
      build_dag(base_ref, MapSet.new(present_branches))
    else
      %Dag{nodes: [], edges: []}
    end
  end

  def lifecycle(nil, _present_branches), do: %Dag{nodes: [], edges: []}

  defp build_dag(root, present_set) do
    levels = bfs_levels(root)
    branches = Map.keys(levels)
    branch_set = MapSet.new(branches)

    nodes =
      branches
      |> Enum.map(fn name ->
        %Node{
          name: name,
          kind: kind(name),
          level: Map.fetch!(levels, name),
          present: MapSet.member?(present_set, name)
        }
      end)
      |> Enum.sort_by(&{&1.level, &1.name})

    edges =
      for from <- branches,
          to <- next_branches(from),
          MapSet.member?(branch_set, to),
          do: %Edge{from: from, to: to}

    %Dag{nodes: nodes, edges: edges}
  end

  defp bfs_levels(root) do
    do_bfs([{root, 0}], %{})
  end

  defp do_bfs([], levels), do: levels

  defp do_bfs([{name, level} | rest], levels) do
    case Map.fetch(levels, name) do
      {:ok, _} ->
        do_bfs(rest, levels)

      :error ->
        levels = Map.put(levels, name, level)
        next = Enum.map(next_branches(name), &{&1, level + 1})
        do_bfs(rest ++ next, levels)
    end
  end
end

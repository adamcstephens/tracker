defmodule Tracker.Nixpkgs.PackageHistory do
  @moduledoc """
  Read-side derivations over `Tracker.Nixpkgs.PackageSpan`.

  Package added/removed/version-change history is no longer materialised as
  event or snapshot rows — it is derived from span boundaries on read. These
  functions compose `PackageSpan` code interfaces and fold the spans in Elixir
  (per-package history is small; point-in-time diffs touch one channel).
  """

  alias Tracker.Nixpkgs.{ChannelRevision, PackageSpan}

  defmodule Event do
    @moduledoc "A derived package lifecycle event (added/removed) at a revision."
    use TypedStruct

    typedstruct enforce: true do
      field :type, :added | :removed
      field :package, Tracker.Nixpkgs.Package.t() | nil, enforce: false
      field :channel_revision, ChannelRevision.t()
    end
  end

  defmodule VersionChange do
    @moduledoc """
    A revision where a package's version changed from the previous span in the
    same channel (the first appearance counts as a change). Derived from a
    package span's opening boundary.
    """
    use TypedStruct

    typedstruct enforce: true do
      field :id, integer()
      field :version, String.t()
      field :package_id, integer()
      field :channel_revision_id, integer()
      field :channel_name, String.t()
      field :revision, String.t()
      field :released_at, DateTime.t()
    end
  end

  @doc """
  A package's version-change history as `VersionChange` structs, one per span
  whose version differs from the previous span in the same channel (first
  appearance included).

  Options: `:channel_id` (scope to one channel), `:version` (substring filter),
  `:sort_by` (`:released_at` default | `:version`), `:sort_dir` (`:desc`
  default | `:asc`), `:limit`, `:offset` (default 0). Returns `{results, count}`
  where `count` is the total matching before pagination.
  """
  @spec version_changes_by_package(integer(), keyword()) ::
          {[VersionChange.t()], non_neg_integer()}
  def version_changes_by_package(package_id, opts \\ []) do
    channel_id = Keyword.get(opts, :channel_id)

    change_spans =
      package_id
      |> PackageSpan.by_package!(channel_id, load: [:channel])
      |> Enum.group_by(& &1.channel_id)
      |> Enum.flat_map(fn {_cid, spans} -> version_change_spans(spans) end)

    revisions = revision_map(change_spans)

    change_spans
    |> Enum.map(&to_version_change(&1, package_id, revisions))
    |> maybe_filter_version(Keyword.get(opts, :version))
    |> sort_changes(
      Keyword.get(opts, :sort_by, :released_at),
      Keyword.get(opts, :sort_dir, :desc)
    )
    |> paginate(Keyword.get(opts, :limit), Keyword.get(opts, :offset, 0))
  end

  # Spans (one channel) whose version differs from the chronological predecessor.
  defp version_change_spans(spans) do
    spans
    |> Enum.sort_by(& &1.valid.lower, DateTime)
    |> Enum.reduce({[], :none}, fn span, {acc, prev} ->
      if span.version == prev, do: {acc, prev}, else: {[span | acc], span.version}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # %{{channel_id, released_at_second} => ChannelRevision} for the spans' lower bounds.
  defp revision_map(spans) do
    spans
    |> Enum.group_by(& &1.channel_id, &released_at(&1))
    |> Enum.flat_map(fn {channel_id, ats} ->
      channel_id
      |> ChannelRevision.by_released_ats!(Enum.uniq(ats))
      |> Enum.map(fn rev -> {{channel_id, released_at_second(rev.released_at)}, rev} end)
    end)
    |> Map.new()
  end

  defp to_version_change(span, package_id, revisions) do
    rev = Map.fetch!(revisions, {span.channel_id, released_at_second(released_at(span))})

    %VersionChange{
      id: span.id,
      version: span.version,
      package_id: package_id,
      channel_revision_id: rev.id,
      channel_name: span.channel.name,
      revision: rev.revision,
      released_at: rev.released_at
    }
  end

  @doc """
  A package's lifecycle events (added/removed) in a channel, derived from span
  boundaries: a span opening that is not contiguous with the previous span's
  close is an `:added` (first appearance or re-addition); a span close not
  continued by the next span — or a bounded final span — is a `:removed`. Each
  event carries the `channel_revision` (with `:channel`) at its boundary, newest
  first.
  """
  @spec events_by_package(integer(), integer()) :: [Event.t()]
  def events_by_package(package_id, channel_id) do
    spans =
      package_id
      |> PackageSpan.by_package!(channel_id)
      |> Enum.sort_by(& &1.valid.lower, DateTime)

    boundaries = boundary_events(spans)
    revisions = boundary_revision_map(channel_id, boundaries)

    boundaries
    |> Enum.map(fn {type, at} ->
      %Event{
        type: type,
        channel_revision: Map.fetch!(revisions, released_at_second(at))
      }
    end)
    |> Enum.sort_by(& &1.channel_revision.released_at, {:desc, DateTime})
  end

  # [{:added | :removed, released_at}] boundaries for a channel's sorted spans.
  defp boundary_events(spans) do
    {events, last} =
      Enum.reduce(spans, {[], nil}, fn span, {acc, prev} ->
        lower = span.valid.lower

        acc =
          cond do
            is_nil(prev) -> [{:added, lower} | acc]
            DateTime.compare(upper_bound(prev.valid), lower) == :eq -> acc
            true -> [{:added, lower}, {:removed, upper_bound(prev.valid)} | acc]
          end

        {acc, span}
      end)

    case last && upper_bound(last.valid) do
      nil -> events
      upper -> [{:removed, upper} | events]
    end
  end

  defp boundary_revision_map(_channel_id, []), do: %{}

  defp boundary_revision_map(channel_id, boundaries) do
    ats = boundaries |> Enum.map(fn {_type, at} -> at end) |> Enum.uniq()

    channel_id
    |> ChannelRevision.by_released_ats!(ats, load: [:channel])
    |> Map.new(fn rev -> {released_at_second(rev.released_at), rev} end)
  end

  @doc """
  Current (open-span) metadata for a set of packages in a channel as
  `%{package_id => PackageSpan.t()}`, served by the `upper_inf` partial index.
  """
  @spec current_metadata(integer(), [integer()]) :: %{integer() => PackageSpan.t()}
  def current_metadata(_channel_id, []), do: %{}

  def current_metadata(channel_id, package_ids) do
    channel_id
    |> PackageSpan.current_for_packages!(package_ids)
    |> Map.new(&{&1.package_id, &1})
  end

  @doc """
  The package's version at every revision of a channel (the "all revisions"
  view), reconstructed by range-containment. Returns
  `%{results, count, more?}` where each result is
  `%{version:, channel_revision:}` (the revision loaded with `:channel`).

  Options: `:version` (substring filter), `:sort_by`/`:sort_dir`, `:limit`,
  `:offset` (default 0).
  """
  @spec revisions_by_package(integer(), integer(), keyword()) :: %{
          results: [map()],
          count: non_neg_integer(),
          more?: boolean()
        }
  def revisions_by_package(package_id, channel_id, opts \\ []) do
    spans = PackageSpan.by_package!(package_id, channel_id)
    limit = Keyword.get(opts, :limit)
    offset = Keyword.get(opts, :offset, 0)

    rows =
      channel_id
      |> ChannelRevision.by_channel_asc!(load: [:channel])
      |> Enum.flat_map(fn rev ->
        case covering_span(spans, rev.released_at) do
          nil -> []
          span -> [%{version: span.version, channel_revision: rev}]
        end
      end)
      |> maybe_filter_version(Keyword.get(opts, :version))
      |> sort_revisions(
        Keyword.get(opts, :sort_by, :released_at),
        Keyword.get(opts, :sort_dir, :desc)
      )

    count = length(rows)
    results = if limit, do: Enum.slice(rows, offset, limit), else: rows

    %{results: results, count: count, more?: limit != nil and offset + limit < count}
  end

  @doc """
  Classifies how each of `package_ids` changed at `revision` relative to its
  predecessor, as `%{package_id => :package_added | :package_removed |
  :package_version_changed}`. Packages with no change are omitted. Used by the
  notification fan-out; `revision` must have a predecessor.
  """
  @spec changed_types(ChannelRevision.t(), [integer()]) :: %{integer() => atom()}
  def changed_types(_revision, []), do: %{}

  def changed_types(revision, package_ids) do
    [prev] = ChannelRevision.by_ids!([revision.previous_channel_revision_id])

    new = at_versions(revision.channel_id, revision.released_at, package_ids)
    old = at_versions(prev.channel_id, prev.released_at, package_ids)

    for pid <- package_ids,
        type = classify(Map.fetch(old, pid), Map.fetch(new, pid)),
        not is_nil(type),
        into: %{} do
      {pid, type}
    end
  end

  defp classify(:error, {:ok, _}), do: :package_added
  defp classify({:ok, _}, :error), do: :package_removed
  defp classify({:ok, v}, {:ok, v}), do: nil
  defp classify({:ok, _}, {:ok, _}), do: :package_version_changed
  defp classify(:error, :error), do: nil

  @doc """
  Resolves the version of each of `package_ids` at each of `revision_ids` as
  `%{{package_id, channel_revision_id} => version}`, reconstructed from the
  spans valid at each revision's `released_at`. Used to render version bumps.
  """
  @spec versions_at_revisions([integer()], [integer()]) :: %{{integer(), integer()} => String.t()}
  def versions_at_revisions([], _package_ids), do: %{}
  def versions_at_revisions(_revision_ids, []), do: %{}

  def versions_at_revisions(revision_ids, package_ids) do
    revisions = ChannelRevision.by_ids!(Enum.uniq(revision_ids))

    for rev <- revisions,
        span <- PackageSpan.at_for_packages!(rev.channel_id, rev.released_at, package_ids),
        into: %{} do
      {{span.package_id, rev.id}, span.version}
    end
  end

  defp at_versions(channel_id, at, package_ids) do
    channel_id
    |> PackageSpan.at_for_packages!(at, package_ids)
    |> Map.new(&{&1.package_id, &1.version})
  end

  defp covering_span(spans, at), do: Enum.find(spans, &range_contains?(&1.valid, at))

  defp range_contains?(%Postgrex.Range{lower: lower} = range, at) do
    (is_nil(lower) or DateTime.compare(at, lower) != :lt) and
      case upper_bound(range) do
        nil -> true
        upper -> DateTime.compare(at, upper) == :lt
      end
  end

  defp sort_revisions(rows, :version, dir), do: Enum.sort_by(rows, & &1.version, dir)

  defp sort_revisions(rows, :channel_name, dir),
    do: Enum.sort_by(rows, & &1.channel_revision.channel.name, dir)

  defp sort_revisions(rows, :revision_hash, dir),
    do: Enum.sort_by(rows, & &1.channel_revision.revision, dir)

  defp sort_revisions(rows, _released_at, dir),
    do: Enum.sort_by(rows, & &1.channel_revision.released_at, {dir, DateTime})

  defp upper_bound(%Postgrex.Range{upper: upper}) when upper in [nil, :unbound], do: nil
  defp upper_bound(%Postgrex.Range{upper: upper}), do: upper

  defp released_at(span), do: span.valid.lower
  defp released_at_second(%DateTime{} = at), do: DateTime.truncate(at, :second)

  defp maybe_filter_version(list, blank) when blank in [nil, ""], do: list

  defp maybe_filter_version(list, version),
    do: Enum.filter(list, &String.contains?(&1.version, version))

  defp sort_changes(list, :version, dir), do: Enum.sort_by(list, & &1.version, dir)

  defp sort_changes(list, _released_at, dir),
    do: Enum.sort_by(list, & &1.released_at, {dir, DateTime})

  defp paginate(list, nil, _offset), do: {list, length(list)}

  defp paginate(list, limit, offset) do
    {Enum.slice(list, offset, limit), length(list)}
  end

  @doc """
  Net package added/removed events between two points on a channel: packages
  present at `to_rev` but not at `from_at` are `:added`, and vice versa for
  `:removed`. Both are attributed to `to_rev` (the boundary revision).
  """
  @spec events_between(ChannelRevision.t(), DateTime.t()) :: [Event.t()]
  def events_between(to_rev, from_at) do
    channel_id = to_rev.channel_id
    old = PackageSpan.at!(channel_id, from_at, load: [:package])
    new = PackageSpan.at!(channel_id, to_rev.released_at, load: [:package])

    old_ids = MapSet.new(old, & &1.package_id)
    new_ids = MapSet.new(new, & &1.package_id)

    added =
      for span <- new, not MapSet.member?(old_ids, span.package_id) do
        %Event{type: :added, package: span.package, channel_revision: to_rev}
      end

    removed =
      for span <- old, not MapSet.member?(new_ids, span.package_id) do
        %Event{type: :removed, package: span.package, channel_revision: to_rev}
      end

    added ++ removed
  end
end

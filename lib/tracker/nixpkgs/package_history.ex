defmodule Tracker.Nixpkgs.PackageHistory do
  @moduledoc """
  Read-side derivations over `Tracker.Nixpkgs.PackageSpan`.

  Package added/removed/version-change history is no longer materialised as
  event or snapshot rows — it is derived from span boundaries on read. These
  functions compose `PackageSpan` code interfaces and fold the spans in Elixir
  (per-package history is small; point-in-time diffs touch one channel).
  """

  alias Tracker.Nixpkgs.{Channel, ChannelRevision, Package, PackageSpan}
  alias Tracker.Nixpkgs.ChannelRevision.VersionDiff

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
      field :position, String.t() | nil, enforce: false
      field :package_id, integer()
      field :channel_revision_id, integer()
      field :channel_name, String.t()
      field :revision, String.t()
      field :released_at, DateTime.t()
      field :added?, boolean()
    end
  end

  defmodule Removal do
    @moduledoc """
    The revision a package left a channel at, derived from a span's closing
    boundary. `version` is the version the closing span carried, so a
    version-filtered list keeps the removal that ended a matching version.
    """
    use TypedStruct

    typedstruct enforce: true do
      field :version, String.t()
      field :channel_name, String.t()
      field :revision, String.t()
      field :released_at, DateTime.t()
    end
  end

  @doc """
  A package's version-change history as `VersionChange` structs, one per span
  whose version differs from the previous span in the same channel (first
  appearance included). `added?` marks the ones sitting on an `:added`
  boundary.

  Options: `:channel_id` (scope to one channel), `:version` (substring filter),
  `:sort_by` (`:released_at` default | `:version`), `:sort_dir` (`:desc`
  default | `:asc`), `:limit`, `:offset` (default 0), `:removals?` (mix in a
  `Removal` at each closing boundary — off by default, so the Atom feed keeps
  update entries only). Returns `{results, count}` where `count` is the total
  matching before pagination.
  """
  @spec version_changes_by_package(integer(), keyword()) ::
          {[VersionChange.t() | Removal.t()], non_neg_integer()}
  def version_changes_by_package(package_id, opts \\ []) do
    spans_by_channel =
      spans_by_channel(package_id, Keyword.get(opts, :channel_id), load: [:channel])

    added = Map.new(spans_by_channel, fn {cid, spans} -> {cid, added_ats(spans)} end)

    change_spans =
      Enum.flat_map(spans_by_channel, fn {_cid, spans} -> version_change_spans(spans) end)

    removals =
      if Keyword.get(opts, :removals?, false) do
        Enum.flat_map(spans_by_channel, fn {_cid, spans} -> Map.to_list(removal_ats(spans)) end)
      else
        []
      end

    revisions =
      revision_map(
        Enum.map(change_spans, &{&1.channel_id, released_at(&1)}) ++
          Enum.map(removals, fn {at, span} -> {span.channel_id, at} end)
      )

    changes = Enum.map(change_spans, &to_version_change(&1, package_id, revisions, added))
    removal_rows = Enum.map(removals, &to_removal(&1, revisions))

    (changes ++ removal_rows)
    |> maybe_filter_version(Keyword.get(opts, :version))
    |> sort_changes(
      Keyword.get(opts, :sort_by, :released_at),
      Keyword.get(opts, :sort_dir, :desc)
    )
    |> paginate(Keyword.get(opts, :limit), Keyword.get(opts, :offset, 0))
  end

  @doc """
  The package's terminal removal from a channel — the close of its latest span
  there — or nil when that span is open. A package removed and re-added is
  present, so it has no terminal removal; neither has one still present, nor
  one that was never in the channel.
  """
  @spec terminal_removal(integer(), integer()) :: Removal.t() | nil
  def terminal_removal(package_id, channel_id) do
    spans = Map.get(spans_by_channel(package_id, channel_id, load: [:channel]), channel_id, [])

    with span when not is_nil(span) <- List.last(spans),
         at when not is_nil(at) <- upper_bound(span.valid) do
      to_removal({at, span}, revision_map([{channel_id, at}]))
    end
  end

  @doc """
  Whether the package has no open span in any channel still taking revisions.

  A retired channel stops getting revisions, so its final spans never close and
  every package in it would read as present forever — the check only means
  anything over live (`status != :retired`) channels.
  """
  @spec absent_from_live_channels?(integer()) :: boolean()
  def absent_from_live_channels?(package_id) do
    live_ids = Enum.map(Channel.active!(), & &1.id)

    is_nil(PackageSpan.open_in_channels!(package_id, live_ids))
  end

  # A package's spans per channel, each group in chronological order — the shape
  # the boundary folds below read.
  defp spans_by_channel(package_id, channel_id, opts \\ []) do
    package_id
    |> PackageSpan.by_package!(channel_id, opts)
    |> Enum.group_by(& &1.channel_id)
    |> Map.new(fn {cid, spans} -> {cid, Enum.sort_by(spans, & &1.valid.lower, DateTime)} end)
  end

  # The instants a channel's sorted spans open an :added boundary at, truncated
  # to match revision timestamps.
  defp added_ats(spans) do
    for {:added, at, _span} <- boundary_events(spans),
        into: MapSet.new(),
        do: released_at_second(at)
  end

  # The instants a channel's sorted spans close a :removed boundary at, each
  # mapped to the span that closed — the removal row wears its version.
  defp removal_ats(spans) do
    for {:removed, at, span} <- boundary_events(spans),
        into: %{},
        do: {released_at_second(at), span}
  end

  # Spans (one channel, sorted) whose version differs from the predecessor.
  defp version_change_spans(spans) do
    spans
    |> Enum.reduce({[], :none}, fn span, {acc, prev} ->
      if span.version == prev, do: {acc, prev}, else: {[span | acc], span.version}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # %{{channel_id, released_at_second} => ChannelRevision} for `{channel_id, at}`
  # boundary points, one query per channel.
  defp revision_map(points) do
    points
    |> Enum.group_by(fn {cid, _at} -> cid end, fn {_cid, at} -> at end)
    |> Enum.flat_map(fn {channel_id, ats} ->
      channel_id
      |> ChannelRevision.by_released_ats!(Enum.uniq(ats))
      |> Enum.map(fn rev -> {{channel_id, released_at_second(rev.released_at)}, rev} end)
    end)
    |> Map.new()
  end

  defp to_version_change(span, package_id, revisions, added) do
    at = released_at_second(released_at(span))
    rev = Map.fetch!(revisions, {span.channel_id, at})

    %VersionChange{
      id: span.id,
      version: span.version,
      position: span.position,
      package_id: package_id,
      channel_revision_id: rev.id,
      channel_name: span.channel.name,
      revision: rev.revision,
      released_at: rev.released_at,
      added?: MapSet.member?(Map.fetch!(added, span.channel_id), at)
    }
  end

  # [{:added | :removed, released_at, span}] boundaries for a channel's sorted
  # spans — the span that opened at an :added, the one that closed at a
  # :removed.
  defp boundary_events(spans) do
    {events, last} =
      Enum.reduce(spans, {[], nil}, fn span, {acc, prev} ->
        lower = span.valid.lower

        acc =
          cond do
            is_nil(prev) -> [{:added, lower, span} | acc]
            DateTime.compare(upper_bound(prev.valid), lower) == :eq -> acc
            true -> [{:added, lower, span}, {:removed, upper_bound(prev.valid), prev} | acc]
          end

        {acc, span}
      end)

    case last && upper_bound(last.valid) do
      nil -> events
      upper -> [{:removed, upper, last} | events]
    end
  end

  defp to_removal({at, span}, revisions) do
    rev = Map.fetch!(revisions, {span.channel_id, released_at_second(at)})

    %Removal{
      version: span.version,
      channel_name: span.channel.name,
      revision: rev.revision,
      released_at: rev.released_at
    }
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
  Point-in-time metadata for a set of packages in a channel as
  `%{package_id => PackageSpan.t()}`. The pinned-lens counterpart of
  `current_metadata/2`; packages with no span at `at` are absent.
  """
  @spec metadata_at(integer(), DateTime.t(), [integer()]) :: %{integer() => PackageSpan.t()}
  def metadata_at(_channel_id, _at, []), do: %{}

  def metadata_at(channel_id, at, package_ids) do
    channel_id
    |> PackageSpan.at_for_packages!(at, package_ids)
    |> Map.new(&{&1.package_id, &1})
  end

  # pname is stored on spans but doesn't count towards a span "having"
  # metadata — it duplicates the attribute for display purposes.
  @metadata_fields [
    :description,
    :long_description,
    :homepage,
    :position,
    :licenses,
    :main_program,
    :outputs,
    :default_output,
    :broken,
    :unfree,
    :insecure,
    :unsupported,
    :known_vulnerabilities,
    :platforms,
    :bad_platforms,
    :changelog,
    :download_page,
    :source_provenance
  ]

  @doc "The span fields that carry package metadata (as opposed to identity/version)."
  @spec metadata_fields() :: [atom()]
  def metadata_fields, do: @metadata_fields

  @doc """
  Whether a span carries no metadata at all — true for spans written before
  metadata was ingested on every channel. Such spans should fall back to the
  metadata channel for display.
  """
  @spec metadata_missing?(PackageSpan.t()) :: boolean()
  def metadata_missing?(span) do
    Enum.all?(@metadata_fields, &is_nil(Map.get(span, &1)))
  end

  @doc """
  The package's version at every revision of a channel (the "all revisions"
  view), reconstructed by range-containment. Returns
  `%{results, count, more?}` where each result is
  `%{version:, position:, channel_revision:, added?:}` (the revision loaded with
  `:channel`; `added?` marks the revision the package appeared at), or a
  `Removal` at each revision the package left at. Revisions inside a gap
  between a removal and a re-addition produce no row, so the gap reads as one.

  Options: `:version` (substring filter), `:sort_by`/`:sort_dir`, `:limit`,
  `:offset` (default 0).
  """
  @spec revisions_by_package(integer(), integer() | nil, keyword()) :: %{
          results: [map() | Removal.t()],
          count: non_neg_integer(),
          more?: boolean()
        }
  def revisions_by_package(package_id, channel_id, opts \\ []) do
    limit = Keyword.get(opts, :limit)
    offset = Keyword.get(opts, :offset, 0)

    rows =
      package_id
      |> spans_by_channel(channel_id)
      |> Enum.flat_map(fn {cid, spans} ->
        added = added_ats(spans)
        removals = removal_ats(spans)

        cid
        |> ChannelRevision.by_channel_asc!(load: [:channel])
        |> Enum.flat_map(&revision_row(&1, spans, added, removals))
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

  defp revision_row(rev, spans, added, removals) do
    at = released_at_second(rev.released_at)

    case covering_span(spans, rev.released_at) do
      nil ->
        removal_row(rev, Map.get(removals, at))

      span ->
        [
          %{
            version: span.version,
            position: span.position,
            channel_revision: rev,
            added?: MapSet.member?(added, at)
          }
        ]
    end
  end

  defp removal_row(_rev, nil), do: []

  defp removal_row(rev, span) do
    [
      %Removal{
        version: span.version,
        channel_name: rev.channel.name,
        revision: rev.revision,
        released_at: rev.released_at
      }
    ]
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

    spans_by_channel =
      revisions
      |> Enum.map(& &1.channel_id)
      |> Enum.uniq()
      |> Map.new(&{&1, PackageSpan.for_packages!(&1, package_ids)})

    for rev <- revisions,
        span <- spans_by_channel[rev.channel_id],
        range_contains?(span.valid, rev.released_at),
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

  defp sort_revisions(rows, :channel_name, dir), do: Enum.sort_by(rows, &row_channel_name/1, dir)

  defp sort_revisions(rows, :revision_hash, dir), do: Enum.sort_by(rows, &row_revision/1, dir)

  defp sort_revisions(rows, _released_at, dir),
    do: Enum.sort_by(rows, &row_released_at/1, {dir, DateTime})

  # A removal row flattens what a version row nests under its revision, so the
  # two shapes sort together.
  defp row_channel_name(%Removal{channel_name: name}), do: name
  defp row_channel_name(%{channel_revision: %{channel: %{name: name}}}), do: name

  defp row_revision(%Removal{revision: revision}), do: revision
  defp row_revision(%{channel_revision: %{revision: revision}}), do: revision

  defp row_released_at(%Removal{released_at: released_at}), do: released_at
  defp row_released_at(%{channel_revision: %{released_at: released_at}}), do: released_at

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
  Package diff between two points on a channel as `%{events, version_changes}`,
  from a single DB-side set-diff so only changed rows reach Elixir. Correct for
  any revision pair, adjacent or not. `events` are added/removed packages
  attributed to `to_rev`; `version_changes` are `VersionDiff`s where the version
  differs (added/removed included).
  """
  @spec diff_between(ChannelRevision.t(), DateTime.t()) :: %{
          events: [Event.t()],
          version_changes: [VersionDiff.t()]
        }
  def diff_between(to_rev, from_at) do
    rows =
      to_rev.channel_id
      |> diff_rows(from_at, to_rev.released_at)
      |> with_attributes()

    version_changes =
      Enum.map(rows, fn r ->
        %VersionDiff{
          attribute: r.attribute,
          old_version: r.old_version,
          new_version: r.new_version
        }
      end)

    %{events: package_events(rows, to_rev), version_changes: version_changes}
  end

  defp with_attributes([]), do: []

  defp with_attributes(rows) do
    attributes =
      rows
      |> Enum.map(& &1.package_id)
      |> Package.by_ids!()
      |> Map.new(&{&1.id, &1.attribute})

    rows
    |> Enum.map(&Map.put(&1, :attribute, Map.fetch!(attributes, &1.package_id)))
    |> Enum.sort_by(& &1.attribute)
  end

  @doc """
  Net package added/removed events between two points on a channel, attributed
  to `to_rev`.
  """
  @spec events_between(ChannelRevision.t(), DateTime.t()) :: [Event.t()]
  def events_between(to_rev, from_at), do: diff_between(to_rev, from_at).events

  defp package_events(rows, to_rev) do
    for r <- rows, not (r.in_old and r.in_new) do
      %Event{
        type: if(r.in_new, do: :added, else: :removed),
        package: %Tracker.Nixpkgs.Package{id: r.package_id, attribute: r.attribute},
        channel_revision: to_rev
      }
    end
  end

  # A package whose version differs across the window must have the span holding
  # `from_at` close inside it and the span holding `to_at` open inside it — one
  # of the two is missing when the package is added or removed, and both are when
  # nothing changed. So the boundary indexes alone carry both endpoints, and cost
  # tracks the size of the diff rather than the size of the channel. A package
  # that changes and changes back matches both and falls out of the comparison.
  defp diff_rows(channel_id, from_at, to_at) do
    {:ok, %{rows: rows}} =
      Tracker.Repo.query(
        """
        WITH old_spans AS (
               SELECT package_id, version FROM package_spans
               WHERE channel_id = $1
                 AND upper(valid) > $2::timestamptz AND upper(valid) <= $3::timestamptz
                 AND valid @> $2::timestamptz
             ),
             new_spans AS (
               SELECT package_id, version FROM package_spans
               WHERE channel_id = $1
                 AND lower(valid) > $2::timestamptz AND lower(valid) <= $3::timestamptz
                 AND valid @> $3::timestamptz
             )
        SELECT o.package_id IS NOT NULL AS in_old,
               n.package_id IS NOT NULL AS in_new,
               o.version, n.version,
               COALESCE(o.package_id, n.package_id) AS package_id
        FROM old_spans o FULL OUTER JOIN new_spans n ON o.package_id = n.package_id
        WHERE o.version IS DISTINCT FROM n.version
        """,
        [channel_id, from_at, to_at]
      )

    Enum.map(rows, fn [in_old, in_new, old_version, new_version, package_id] ->
      %{
        in_old: in_old,
        in_new: in_new,
        old_version: old_version,
        new_version: new_version,
        package_id: package_id
      }
    end)
  end
end

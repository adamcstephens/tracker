defmodule Tracker.Nixpkgs.OptionHistory do
  @moduledoc """
  Read-side derivations over `Tracker.Nixpkgs.OptionSpan`.

  Option added/removed events and metadata diffs are no longer materialised as
  event rows — they are derived from span boundaries on read. These functions
  compose `OptionSpan` code interfaces and fold the spans in Elixir. See
  `Tracker.Nixpkgs.PackageHistory` for the package-side equivalent.
  """

  alias Tracker.Nixpkgs.{ChannelRevision, Option, OptionSpan}

  defmodule Event do
    @moduledoc "A derived option lifecycle event (added/removed) at a revision."
    use TypedStruct

    typedstruct enforce: true do
      field :type, :added | :removed
      field :option, Tracker.Nixpkgs.Option.t()
      field :channel_revision, ChannelRevision.t()
    end
  end

  defmodule MetadataDiff do
    @moduledoc "A single option metadata field that changed between two revisions."
    use TypedStruct

    @type field_name :: :description | :type | :default | :example | :read_only

    typedstruct enforce: true do
      field :option_name, String.t()
      field :field, field_name()
      field :old, String.t() | boolean() | nil
      field :new, String.t() | boolean() | nil
    end
  end

  @metadata_fields [:description, :type, :default, :example, :read_only]

  @doc """
  Option diff between two points on a channel as `%{events, metadata_changes}`,
  from a single DB-side set-diff so only changed rows reach Elixir. Correct for
  any revision pair. `events` are added/removed options attributed to `to_rev`;
  `metadata_changes` are per-field `MetadataDiff`s for options present in both.
  """
  @spec diff_between(ChannelRevision.t(), DateTime.t()) :: %{
          events: [Event.t()],
          metadata_changes: [MetadataDiff.t()]
        }
  def diff_between(to_rev, from_at) do
    rows =
      to_rev.channel_id
      |> diff_rows(from_at, to_rev.released_at)
      |> with_names()

    %{events: option_events(rows, to_rev), metadata_changes: metadata_changes(rows)}
  end

  defp with_names([]), do: []

  defp with_names(rows) do
    names =
      rows
      |> Enum.map(& &1.option_id)
      |> Option.by_ids!()
      |> Map.new(&{&1.id, &1.name})

    rows
    |> Enum.map(&Map.put(&1, :name, Map.fetch!(names, &1.option_id)))
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Net option added/removed events between two points on a channel, attributed
  to `to_rev`.
  """
  @spec events_between(ChannelRevision.t(), DateTime.t()) :: [Event.t()]
  def events_between(to_rev, from_at), do: diff_between(to_rev, from_at).events

  @doc """
  Metadata field changes between two channel revisions as `MetadataDiff` structs
  — options present in both, one struct per changed field (description, type,
  default, example, read_only).
  """
  @spec metadata_diff(ChannelRevision.t(), ChannelRevision.t()) :: [MetadataDiff.t()]
  def metadata_diff(from_rev, to_rev),
    do: diff_between(to_rev, from_rev.released_at).metadata_changes

  defp option_events(rows, to_rev) do
    for r <- rows, not (r.in_old and r.in_new) do
      %Event{
        type: if(r.in_new, do: :added, else: :removed),
        option: %Tracker.Nixpkgs.Option{id: r.option_id, name: r.name},
        channel_revision: to_rev
      }
    end
  end

  defp metadata_changes(rows) do
    rows
    |> Enum.filter(&(&1.in_old and &1.in_new))
    |> Enum.flat_map(fn r ->
      Enum.flat_map(@metadata_fields, fn field ->
        old = Map.fetch!(r.old, field)
        new = Map.fetch!(r.new, field)

        if old == new,
          do: [],
          else: [%MetadataDiff{option_name: r.name, field: field, old: old, new: new}]
      end)
    end)
    |> Enum.sort_by(&{&1.option_name, &1.field})
  end

  # An option whose metadata differs across the window must have the span holding
  # `from_at` close inside it and the span holding `to_at` open inside it — one of
  # the two is missing when the option is added or removed, and both are when
  # nothing changed. So the boundary indexes alone carry both endpoints, and cost
  # tracks the size of the diff rather than the size of the channel. Spans also
  # cut on payload fields not compared here, which land in the join and fall out
  # of the field comparison.
  defp diff_rows(channel_id, from_at, to_at) do
    {:ok, %{rows: rows}} =
      Tracker.Repo.query(
        """
        WITH old_spans AS (
               SELECT option_id, description, type, "default", example, read_only
               FROM option_spans
               WHERE channel_id = $1
                 AND upper(valid) > $2::timestamptz AND upper(valid) <= $3::timestamptz
                 AND valid @> $2::timestamptz
             ),
             new_spans AS (
               SELECT option_id, description, type, "default", example, read_only
               FROM option_spans
               WHERE channel_id = $1
                 AND lower(valid) > $2::timestamptz AND lower(valid) <= $3::timestamptz
                 AND valid @> $3::timestamptz
             )
        SELECT o.option_id IS NOT NULL AS in_old,
               n.option_id IS NOT NULL AS in_new,
               o.description, n.description, o.type, n.type,
               o."default", n."default", o.example, n.example,
               o.read_only, n.read_only,
               COALESCE(o.option_id, n.option_id) AS option_id
        FROM old_spans o FULL OUTER JOIN new_spans n ON o.option_id = n.option_id
        WHERE o.option_id IS NULL OR n.option_id IS NULL
           OR o.description IS DISTINCT FROM n.description
           OR o.type IS DISTINCT FROM n.type
           OR o."default" IS DISTINCT FROM n."default"
           OR o.example IS DISTINCT FROM n.example
           OR o.read_only IS DISTINCT FROM n.read_only
        """,
        [channel_id, from_at, to_at]
      )

    Enum.map(rows, fn [
                        in_old,
                        in_new,
                        o_desc,
                        n_desc,
                        o_type,
                        n_type,
                        o_def,
                        n_def,
                        o_ex,
                        n_ex,
                        o_ro,
                        n_ro,
                        option_id
                      ] ->
      %{
        in_old: in_old,
        in_new: in_new,
        option_id: option_id,
        old: %{description: o_desc, type: o_type, default: o_def, example: o_ex, read_only: o_ro},
        new: %{description: n_desc, type: n_type, default: n_def, example: n_ex, read_only: n_ro}
      }
    end)
  end

  @doc """
  A sorted `[{subgroup, count}, ...]` list for the tree view of a channel's
  options valid at `at` under the given prefix.

  A subgroup is the first `depth(prefix) + 1` dot-separated segments of an
  option name; only options strictly deeper than the subgroup itself are
  counted, mirroring the split between child cards and leaf options. Raw SQL
  because a GROUP BY over a derived name isn't expressible as an Ash read, and
  reconstructing every option under a big prefix like `services` just to count
  names in Elixir costs seconds — the range-containment filter rides the span
  GiST index instead.
  """
  @spec subgroup_counts(integer(), DateTime.t(), String.t()) :: [{String.t(), non_neg_integer()}]
  def subgroup_counts(channel_id, at, prefix \\ "") do
    {pattern, depth} =
      case prefix do
        "" -> {"%.%", 0}
        _ -> {prefix <> ".%.%", length(String.split(prefix, "."))}
      end

    group_regex = "^(?:[^.]+\\.){#{depth}}[^.]+"

    {:ok, %{rows: rows}} =
      Tracker.Repo.query(
        """
        SELECT substring(o.name FROM $3), count(*)
        FROM option_spans s
        JOIN options o ON o.id = s.option_id
        WHERE s.channel_id = $1
          AND s.valid @> $4::timestamptz
          AND o.name LIKE $2
        GROUP BY 1
        """,
        [channel_id, pattern, group_regex, at]
      )

    rows
    |> Enum.map(fn [name, count] -> {name, count} end)
    |> Enum.sort_by(fn {name, _count} -> name end)
  end

  @doc """
  Current (open-span) metadata for a set of options as
  `%{option_id => OptionSpan.t()}`. When an option is open in more than one
  channel, the most recently opened span wins.
  """
  @spec current_metadata([integer()]) :: %{integer() => OptionSpan.t()}
  def current_metadata([]), do: %{}

  def current_metadata(option_ids) do
    option_ids
    |> OptionSpan.current_for_options!()
    |> Enum.group_by(& &1.option_id)
    |> Map.new(fn {option_id, spans} ->
      {option_id, Enum.max_by(spans, & &1.valid.lower, DateTime)}
    end)
  end
end

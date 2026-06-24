defmodule Tracker.Nixpkgs.OptionHistory do
  @moduledoc """
  Read-side derivations over `Tracker.Nixpkgs.OptionSpan`.

  Option added/removed events and metadata diffs are no longer materialised as
  event rows — they are derived from span boundaries on read. These functions
  compose `OptionSpan` code interfaces and fold the spans in Elixir. See
  `Tracker.Nixpkgs.PackageHistory` for the package-side equivalent.
  """

  alias Tracker.Nixpkgs.{ChannelRevision, OptionSpan}

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
    rows = diff_rows(to_rev.channel_id, from_at, to_rev.released_at)
    %{events: option_events(rows, to_rev), metadata_changes: metadata_changes(rows)}
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

  # DB-side set-diff: only options added/removed or with a changed tracked field.
  defp diff_rows(channel_id, from_at, to_at) do
    {:ok, %{rows: rows}} =
      Tracker.Repo.query(
        """
        WITH a AS (SELECT option_id, description, type, "default", example, read_only
                   FROM option_spans WHERE channel_id = $1 AND valid @> $2::timestamptz),
             b AS (SELECT option_id, description, type, "default", example, read_only
                   FROM option_spans WHERE channel_id = $1 AND valid @> $3::timestamptz)
        SELECT o.name,
               a.option_id IS NOT NULL AS in_old,
               b.option_id IS NOT NULL AS in_new,
               a.description, b.description, a.type, b.type,
               a."default", b."default", a.example, b.example,
               a.read_only, b.read_only,
               COALESCE(a.option_id, b.option_id) AS option_id
        FROM a FULL OUTER JOIN b ON a.option_id = b.option_id
        JOIN options o ON o.id = COALESCE(a.option_id, b.option_id)
        WHERE a.option_id IS NULL OR b.option_id IS NULL
           OR a.description IS DISTINCT FROM b.description
           OR a.type IS DISTINCT FROM b.type
           OR a."default" IS DISTINCT FROM b."default"
           OR a.example IS DISTINCT FROM b.example
           OR a.read_only IS DISTINCT FROM b.read_only
        ORDER BY o.name
        """,
        [channel_id, from_at, to_at]
      )

    Enum.map(rows, fn [
                        name,
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
        name: name,
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

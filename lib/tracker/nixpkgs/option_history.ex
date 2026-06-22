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
  Net option added/removed events between two points on a channel: options
  present at `to_rev` but not at `from_at` are `:added`, and vice versa for
  `:removed`. Both are attributed to `to_rev` (the boundary revision), newest
  set first.
  """
  @spec events_between(ChannelRevision.t(), DateTime.t()) :: [Event.t()]
  def events_between(to_rev, from_at) do
    channel_id = to_rev.channel_id
    old = OptionSpan.at!(channel_id, from_at, load: [:option])
    new = OptionSpan.at!(channel_id, to_rev.released_at, load: [:option])

    old_ids = MapSet.new(old, & &1.option_id)
    new_ids = MapSet.new(new, & &1.option_id)

    added =
      for span <- new, not MapSet.member?(old_ids, span.option_id) do
        %Event{type: :added, option: span.option, channel_revision: to_rev}
      end

    removed =
      for span <- old, not MapSet.member?(new_ids, span.option_id) do
        %Event{type: :removed, option: span.option, channel_revision: to_rev}
      end

    added ++ removed
  end

  @doc """
  Metadata changes between two channel revisions as `MetadataDiff` structs.

  Only options present in both revisions are considered, reconstructed from the
  spans valid at each revision's `released_at`. Emits one struct per changed
  field (description, type, default, example, read_only).
  """
  @spec metadata_diff(ChannelRevision.t(), ChannelRevision.t()) :: [MetadataDiff.t()]
  def metadata_diff(from_rev, to_rev) do
    old = at_by_option(from_rev)
    new = at_by_option(to_rev)

    old
    |> Enum.flat_map(fn {option_id, old_span} ->
      case Map.fetch(new, option_id) do
        :error -> []
        {:ok, new_span} -> field_diffs(old_span, new_span)
      end
    end)
    |> Enum.sort_by(&{&1.option_name, &1.field})
  end

  defp field_diffs(old_span, new_span) do
    Enum.flat_map(@metadata_fields, fn field ->
      old = Map.fetch!(old_span, field)
      new = Map.fetch!(new_span, field)

      if old == new do
        []
      else
        [%MetadataDiff{option_name: old_span.option.name, field: field, old: old, new: new}]
      end
    end)
  end

  defp at_by_option(revision) do
    revision.channel_id
    |> OptionSpan.at!(revision.released_at, load: [:option])
    |> Map.new(&{&1.option_id, &1})
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

defmodule Tracker.Nixpkgs.RevisionSummary do
  @moduledoc "Persisted predecessor comparison counts and a bounded, balanced preview."

  use TypedStruct

  alias Tracker.Nixpkgs.{Channel, ChannelRevision, RevisionComparison}
  alias Tracker.Nixpkgs.RevisionComparison.{Counts, OptionRow, PackageRow, Page}

  typedstruct do
    field :counts, Counts.t(), enforce: true
    field :results, [PackageRow.t() | OptionRow.t()], default: []
  end

  def to_page(%__MODULE__{} = summary) do
    counts = summary.counts

    %Page{
      counts: counts,
      count: counts.added + counts.removed + counts.changed,
      results: summary.results
    }
  end

  def persist(%ChannelRevision{} = revision), do: persist(revision, revision)

  def persist(%ChannelRevision{} = revision, %ChannelRevision{} = completed_revision) do
    predecessor =
      if revision.previous_channel_revision_id do
        ChannelRevision.get_by_id!(revision.previous_channel_revision_id)
      end

    channel = Channel.by_id!(revision.channel_id)

    ChannelRevision.record_summaries(revision, %{
      package_summary:
        build(predecessor, completed_revision, :result, &RevisionComparison.packages/3),
      option_summary:
        if String.starts_with?(channel.name, "nixpkgs-") do
          nil
        else
          build(predecessor, completed_revision, :options_result, &RevisionComparison.options/3)
        end
    })
  end

  defp build(nil, %ChannelRevision{}, _result, _compare), do: nil

  defp build(%ChannelRevision{} = predecessor, %ChannelRevision{} = revision, result, compare) do
    if Map.fetch!(predecessor, result) == :success and Map.fetch!(revision, result) == :success do
      page = compare.(predecessor, revision, preview: true)
      %__MODULE__{counts: page.counts, results: page.results}
    end
  end
end

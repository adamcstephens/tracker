defmodule Tracker.Nixpkgs.BackportEvidence do
  @moduledoc """
  Extracts directed source-PR evidence without relying on targets, titles or labels.

  A conventional human head is only a candidate until corroborated. Explicit
  source lists can legitimately describe several originals; disjoint head/body
  evidence or singleton commit associations outside a stated source list make
  the entire conflicting set candidates rather than arbitrarily choosing a source.
  """

  alias Tracker.Nixpkgs.Change

  defmodule Match do
    use TypedStruct

    typedstruct do
      field :source_number, pos_integer(), enforce: true
      field :confidence, :confirmed | :candidate, enforce: true
      field :evidence, [String.t()], default: []
    end
  end

  @reference ~S"(?:https://github\.com/NixOS/nixpkgs/pull/[1-9][0-9]*(?![0-9A-Za-z_/])|NixOS/nixpkgs\#[1-9][0-9]*\b|(?<![\w/\#])\#[1-9][0-9]*\b)"
  @separator ~S"(?:\s*(?:,\s*(?:and\b|&)?|&|\band\b)\s*|\s+)(?:[-*]\s+)?"
  @reference_list @reference <> "(?:" <> @separator <> @reference <> ")*"
  @reference_regex Regex.compile!(@reference, "i")
  @body_marker ~S"\b(?:backports?\s+(?:of|from)|backported\s+from|backport(?:s|ed|ing)?\s*:|backport(?:s|ed|ing)?\s+|cherry[ -]pick(?:ed|ing)?\s+(?:from|of)|bot-based backport to [^\n,]+,\s*triggered by a label in)\s*(?:PRs?\b|pull requests?\b)?\s*:?\s*(?:[-*]\s+)?"
  @body_regex Regex.compile!(@body_marker <> "(" <> @reference_list <> ")", "i")
  @negative_context ~r/\b(?:not|never|without|unlike|please|can|should|could|would|request(?:ed|ing)?|want(?:ed)?|need(?:s|ed)?)\b|\bdon't\b/i

  @sha ~S"(?:https://github\.com/NixOS/nixpkgs/commit/)?\b[0-9a-f]{7,40}\b"
  @sha_list @sha <> "(?:" <> @separator <> @sha <> ")*"
  @commit_marker ~S"\b(?:cherry[ -]pick(?:ed|ing)?(?:\s+(?:from|of))?(?:\s+commits?)?|backported\s+from\s+commits?)\s*:?\s+"
  @commit_regex Regex.compile!(@commit_marker <> "(" <> @sha_list <> ")", "i")

  def extract(%Change{} = change, commit_sources \\ []) do
    head = head_signals(change)
    body = body_signals(change.body || "")
    commits = commit_signals(commit_sources)

    signals =
      (head ++ body ++ commits)
      |> Enum.reject(fn {number, _kind, _evidence} -> number == change.number end)
      |> Enum.uniq()

    heads = source_set(signals, [:head, :bot_head])
    bodies = source_set(signals, [:body])
    singletons = source_set(signals, [:commit])

    conflicting? =
      (MapSet.size(heads) > 0 and MapSet.size(bodies) > 0 and
         not MapSet.subset?(heads, bodies)) or
        (MapSet.size(bodies) > 0 and not MapSet.subset?(singletons, bodies)) or
        (MapSet.size(bodies) == 0 and MapSet.size(heads) > 0 and
           MapSet.size(singletons) > 0 and not MapSet.subset?(heads, singletons))

    signals
    |> Enum.group_by(fn {number, _kind, _evidence} -> number end)
    |> Enum.map(fn {number, evidence} ->
      confirmed? =
        not conflicting? and
          Enum.any?(evidence, fn {_number, kind, _text} ->
            kind in [:body, :bot_head, :commit]
          end)

      %Match{
        source_number: number,
        confidence: if(confirmed?, do: :confirmed, else: :candidate),
        evidence: evidence |> Enum.map(&elem(&1, 2)) |> Enum.uniq() |> Enum.sort()
      }
    end)
    |> Enum.sort_by(& &1.source_number)
  end

  @doc """
  Returns distinct source SHAs from every supplied commit message, in order.

  Both git's cherry-pick trailer and explicit noncanonical cherry-pick prose are
  supported. Missing trailers and unrelated hashes do not imply a source commit.
  Short SHAs are retained for GitHub to resolve; arbitrary foreign commit URLs
  are not interpreted as nixpkgs commits.
  """
  def source_commit_shas(messages) do
    messages
    |> Enum.flat_map(fn
      message when is_binary(message) ->
        @commit_regex
        |> Regex.scan(message, return: :index)
        |> Enum.flat_map(fn [{start, _length}, {sources_start, sources_length}] ->
          if negative_context?(message, start) do
            []
          else
            sources = binary_part(message, sources_start, sources_length)
            Regex.scan(~r/\b[0-9a-f]{7,40}\b/i, sources) |> List.flatten()
          end
        end)

      _other ->
        []
    end)
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  defp head_signals(%Change{} = change) do
    case Regex.run(~r/^backport-([1-9][0-9]*)-to-(\S+)$/, change.head_ref || "") do
      [_head, number, _target] ->
        kind = if change.author in ["nixpkgs-ci", "nixpkgs-ci[bot]"], do: :bot_head, else: :head
        [{String.to_integer(number), kind, "head_ref: #{change.head_ref}"}]

      nil ->
        []
    end
  end

  defp body_signals(body) do
    body =
      body
      |> String.replace(~r/<!--.*?-->/s, "")
      |> String.replace(~r/```.*?```|~~~.*?~~~/s, "")
      |> String.replace(~r/^[\t ]*>.*$/m, "")
      |> String.replace(~r/\[[^\]\n]*\]\(([^\s)]+)\)/, "\\1")
      |> String.replace(~r/`([^`\n]+)`/, "\\1")

    @body_regex
    |> Regex.scan(body, return: :index)
    |> Enum.flat_map(fn [{start, length}, {sources_start, sources_length}] ->
      if negative_context?(body, start) do
        []
      else
        sources = binary_part(body, sources_start, sources_length)
        evidence = "body: " <> String.trim(binary_part(body, start, length))

        @reference_regex
        |> Regex.scan(sources)
        |> Enum.map(fn [reference] ->
          [_reference, number] = Regex.run(~r/(?:\#|\/pull\/)([0-9]+)/i, reference)
          {String.to_integer(number), :body, evidence}
        end)
      end
    end)
  end

  defp negative_context?(text, start) do
    text
    |> binary_part(0, start)
    |> String.split(~r/[.!?\n]/)
    |> List.last()
    |> then(&Regex.match?(@negative_context, &1))
  end

  defp commit_signals(commit_sources) do
    Enum.flat_map(commit_sources, fn sources ->
      sources = sources |> Enum.filter(&(is_integer(&1) and &1 > 0)) |> Enum.uniq() |> Enum.sort()

      case sources do
        [] ->
          []

        [number] ->
          [{number, :commit, "cherry_pick: associated PR ##{number}"}]

        numbers ->
          evidence =
            "cherry_pick: ambiguous associated PRs " <>
              Enum.map_join(numbers, ", ", &"##{&1}")

          Enum.map(numbers, &{&1, :ambiguous_commit, evidence})
      end
    end)
  end

  defp source_set(signals, kinds) do
    signals
    |> Enum.filter(fn {_number, kind, _evidence} -> kind in kinds end)
    |> MapSet.new(fn {number, _kind, _evidence} -> number end)
  end
end

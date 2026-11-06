defmodule Tracker.Nixpkgs.BackportEvidenceTest do
  use ExUnit.Case, async: true

  alias Tracker.Nixpkgs.{BackportEvidence, Change}
  alias Tracker.Nixpkgs.BackportEvidence.Match

  defp change(attrs \\ []) do
    struct!(
      Change,
      Keyword.merge(
        [number: 900, author: "alice", head_ref: "fix-security", body: nil],
        attrs
      )
    )
  end

  defp confidences(matches) do
    Map.new(matches, &{&1.source_number, &1.confidence})
  end

  describe "extract/2" do
    test "known bot spellings confirm conventional heads regardless of retargeting" do
      for author <- ["nixpkgs-ci", "nixpkgs-ci[bot]"],
          target <- ["release-25.11", "staging-25.11", "staging-next"] do
        assert [%Match{source_number: 123, confidence: :confirmed, evidence: [_]}] =
                 BackportEvidence.extract(
                   change(
                     author: author,
                     head_ref: "backport-123-to-#{target}",
                     base_ref: "release-26.05"
                   )
                 )
      end
    end

    test "the configured bot description corroborates its source without matching the base" do
      body = "Bot-based backport to `release-25.11`, triggered by a label in #123."

      assert %{123 => :confirmed} ==
               change(author: "nixpkgs-ci[bot]", body: body, base_ref: "staging-25.11")
               |> BackportEvidence.extract()
               |> confidences()
    end

    test "human and unknown-bot heads need corroboration" do
      for author <- ["alice", "another[bot]", "nixpkgs-ci-impostor"] do
        assert [%Match{source_number: 123, confidence: :candidate}] =
                 BackportEvidence.extract(
                   change(author: author, head_ref: "backport-123-to-release-25.11")
                 )
      end
    end

    test "a generic mention does not corroborate a human head" do
      assert %{123 => :candidate} ==
               change(head_ref: "backport-123-to-staging", body: "Related to #123.")
               |> BackportEvidence.extract()
               |> confidences()
    end

    test "explicit body and singleton commit evidence corroborate a human head" do
      pr = change(head_ref: "backport-123-to-staging", body: "Manual backport of #123.")
      assert %{123 => :confirmed} == confidences(BackportEvidence.extract(pr))

      assert %{123 => :confirmed} ==
               confidences(BackportEvidence.extract(%{pr | body: nil}, [[123]]))
    end

    test "manual comma-separated and whitespace-separated multi-source bodies are confirmed" do
      bodies = [
        "This is a manual backport of #373747, #394341, #394348, #407007.",
        "Manual backport of #373747 #394341 #394348 #407007 to `release-24.11`.",
        "Manual backport of #373747, #394341, #394348, and #407007."
      ]

      for body <- bodies do
        assert %{
                 373_747 => :confirmed,
                 394_341 => :confirmed,
                 394_348 => :confirmed,
                 407_007 => :confirmed
               } ==
                 confidences(BackportEvidence.extract(change(body: body)))
      end
    end

    test "a head corroborated by one of several explicit sources does not conflict" do
      body = "Manual backport of #10, #20 and #30."

      assert %{10 => :confirmed, 20 => :confirmed, 30 => :confirmed} ==
               change(head_ref: "backport-20-to-staging", body: body)
               |> BackportEvidence.extract([[10], [20], [30]])
               |> confidences()
    end

    test "same-repository URLs, shorthand, Markdown links and multiline lists are accepted" do
      bodies = [
        "Backport of https://github.com/NixOS/nixpkgs/pull/10 and NixOS/nixpkgs#20.",
        "Backport of [the original](https://github.com/NixOS/nixpkgs/pull/10), #20.",
        "Backports:\n- #10\n- #20\n\nDepends on #30."
      ]

      for body <- bodies do
        assert %{10 => :confirmed, 20 => :confirmed} ==
                 confidences(BackportEvidence.extract(change(body: body)))
      end
    end

    test "unrelated prerequisites in the same sentence are not sources" do
      body =
        "Manual backport of #371189, as the automatic one failed due to a merge conflict " <>
          "caused by not having backported #368966."

      assert %{371_189 => :confirmed} ==
               confidences(BackportEvidence.extract(change(body: body)))
    end

    test "generic, issue, foreign-repository, requested and negated references are not proof" do
      bodies = [
        "Related to #123. Fixes #456. Depends on #789.",
        "Please backport #123 to stable.",
        "We should backport #123.",
        "Not a backport of #123.",
        "Can someone backport #123 to release-25.11?",
        "Can you backport #123?",
        "Would someone backport #123?",
        "This is not a backport of #123.",
        "Unlike the backport of #123, this is an original fix.",
        "Backport of https://github.com/other/nixpkgs/pull/123.",
        "Backport of other/nixpkgs#123.",
        "Backport of https://github.com/NixOS/nixpkgs/issues/123.",
        "<!-- Backport of #123. -->",
        "```\nBackport of #123\n```",
        "> Backport of #123"
      ]

      for body <- bodies do
        assert [] == BackportEvidence.extract(change(body: body)), body
      end
    end

    test "titles, labels and base branches do not identify sources" do
      assert [] ==
               BackportEvidence.extract(
                 change(
                   title: "[Backport release-25.11] #123 fix",
                   labels: ["backport release-25.11"],
                   base_ref: "release-25.11"
                 )
               )
    end

    test "conflicting human or trusted bot head and body sources are all candidates" do
      for author <- ["alice", "nixpkgs-ci", "nixpkgs-ci[bot]"] do
        assert %{521_564 => :candidate, 521_654 => :candidate} ==
                 change(
                   author: author,
                   head_ref: "backport-521654-to-release-25.11",
                   body: "Backport of #521564"
                 )
                 |> BackportEvidence.extract()
                 |> confidences()
      end
    end

    test "all members of conflicting source sets remain candidates" do
      assert %{10 => :candidate, 20 => :candidate, 30 => :candidate} ==
               change(head_ref: "backport-30-to-staging", body: "Backport of #10 and #20")
               |> BackportEvidence.extract([[10], [20]])
               |> confidences()
    end

    test "singleton commit associations confirm multiple independent sources" do
      assert %{10 => :confirmed, 20 => :confirmed} ==
               confidences(BackportEvidence.extract(change(), [[10], [20], [10], []]))
    end

    test "multiple PR associations of a single commit remain ambiguous" do
      assert %{10 => :candidate, 20 => :candidate} ==
               confidences(BackportEvidence.extract(change(), [[10, 20]]))
    end

    test "an ambiguous association does not overrule independently confirmed provenance" do
      assert %{10 => :confirmed, 20 => :candidate} ==
               change(body: "Backport of #10")
               |> BackportEvidence.extract([[10, 20]])
               |> confidences()
    end

    test "strong commit evidence conflicting with the head or body remains conservative" do
      for pr <- [
            change(head_ref: "backport-10-to-staging"),
            change(body: "Backport of #10"),
            change(body: "Backport of #10 and #20")
          ] do
        matches = BackportEvidence.extract(pr, [[30]])
        assert Enum.all?(matches, &(&1.confidence == :candidate))
        assert Enum.any?(matches, &(&1.source_number == 30))
      end
    end

    test "short backport assertions and PR-prefixed sources identify originals" do
      for body <- [
            "Backport #10 and #20 to release-25.11.",
            "This backports #10 and #20.",
            "Backport of PRs #10 and #20.",
            "Manually backported #10 and #20."
          ] do
        assert %{10 => :confirmed, 20 => :confirmed} ==
                 confidences(BackportEvidence.extract(change(body: body)))
      end
    end

    test "explicit cherry-pick PR language is also provenance" do
      for body <- ["Cherry-picked from #10 and #20.", "Cherry-pick of #10, #20."] do
        assert %{10 => :confirmed, 20 => :confirmed} ==
                 confidences(BackportEvidence.extract(change(body: body)))
      end
    end

    test "self references are excluded and repeated evidence is deduplicated" do
      pr =
        change(
          head_ref: "backport-900-to-staging",
          body: "Backport of #900, #10, #10.\nBackport of #10, #10."
        )

      assert [%Match{source_number: 10, confidence: :confirmed} = match] =
               BackportEvidence.extract(pr, [[900], [10, 10], [10]])

      assert Enum.uniq(match.evidence) == match.evidence
      assert Enum.all?(match.evidence, &is_binary/1)
    end

    test "removing one of multiple ambiguous associations as self does not invent certainty" do
      assert [%Match{source_number: 10, confidence: :candidate}] =
               BackportEvidence.extract(change(), [[900, 10]])
    end

    test "missing fields and malformed conventional heads produce no matches" do
      for head <- [
            nil,
            "backport-0-to-staging",
            "backport-123-to-",
            "fix-backport-123-to-staging"
          ] do
        assert [] == BackportEvidence.extract(change(author: nil, head_ref: head))
      end
    end
  end

  describe "source_commit_shas/1" do
    test "collects all standard trailers from every commit and deduplicates" do
      sha = "e045b360f3515cea97092d9fbdba10da0f953dc0"
      other = "abcdef0123456789abcdef0123456789abcdef01"

      assert [sha, other] ==
               BackportEvidence.source_commit_shas([
                 "fix one\n\n(cherry picked from commit #{sha})",
                 "fix two\n\n(cherry picked from commit #{other})\n" <>
                   "(cherry picked from commit #{sha})"
               ])
    end

    test "accepts noncanonical cherry-pick prose and multiple SHAs" do
      assert ["abcdef0", "1234567", "fedcba9"] ==
               BackportEvidence.source_commit_shas([
                 "Cherry-picked commits abcdef0, 1234567, and fedcba9"
               ])

      assert ["abcdef0", "1234567", "fedcba9"] ==
               BackportEvidence.source_commit_shas([
                 "Cherry-picked commits ABCDEF0 and 1234567.",
                 "Cherry pick from https://github.com/NixOS/nixpkgs/commit/fedcba9"
               ])
    end

    test "backported-from commit prose is recognized" do
      assert ["abcdef0"] ==
               BackportEvidence.source_commit_shas(["Backported from commit abcdef0."])
    end

    test "missing trailers, unrelated SHAs, foreign URLs and invalid SHAs are ignored" do
      assert [] ==
               BackportEvidence.source_commit_shas([
                 nil,
                 "fix without any trailer",
                 "Reverts commit abcdef0",
                 "Related commit abcdef0; should cherry-pick this later.",
                 "Cherry-picked from https://github.com/other/project/commit/abcdef0",
                 "(cherry picked from commit abcdef)",
                 "(cherry picked from commit abcdef0123456789abcdef0123456789abcdef01234)"
               ])
    end
  end
end

defmodule Tracker.Nixpkgs.ChangeTransitionsTest do
  use ExUnit.Case, async: true

  alias Tracker.GitHub.GraphQL.PullRequest
  alias Tracker.Nixpkgs.ChangeTransitions

  defp pr(overrides) do
    defaults = %{
      node_id: "PR_node",
      number: 1,
      title: "test",
      state: :open,
      head_sha: "sha",
      updated_at: ~U[2026-04-23 10:00:00Z]
    }

    struct!(PullRequest, Map.merge(defaults, Map.new(overrides)))
  end

  describe "detect/2" do
    test "open → merged emits :merged" do
      prior = %{state: :open, head_sha: "sha"}

      assert ChangeTransitions.detect(
               prior,
               pr(state: :merged, merged_at: ~U[2026-04-23 10:00:00Z])
             ) ==
               [:merged]
    end

    test "draft → merged emits :merged" do
      prior = %{state: :draft, head_sha: "sha"}

      assert ChangeTransitions.detect(
               prior,
               pr(state: :merged, merged_at: ~U[2026-04-23 10:00:00Z])
             ) ==
               [:merged]
    end

    test "open with head_sha change emits :head_sha_changed" do
      prior = %{state: :open, head_sha: "old"}

      assert ChangeTransitions.detect(prior, pr(state: :open, head_sha: "new")) ==
               [:head_sha_changed]
    end

    test "draft with head_sha change emits :head_sha_changed" do
      prior = %{state: :draft, head_sha: "old"}

      assert ChangeTransitions.detect(prior, pr(state: :draft, head_sha: "new")) ==
               [:head_sha_changed]
    end

    test "open → closed without merge emits :closed_no_merge" do
      prior = %{state: :open, head_sha: "sha"}

      assert ChangeTransitions.detect(prior, pr(state: :closed, merged_at: nil)) ==
               [:closed_no_merge]
    end

    test "draft → closed without merge emits :closed_no_merge" do
      prior = %{state: :draft, head_sha: "sha"}

      assert ChangeTransitions.detect(prior, pr(state: :closed, merged_at: nil)) ==
               [:closed_no_merge]
    end

    test "open → closed with merged_at set does not emit :closed_no_merge" do
      prior = %{state: :open, head_sha: "sha"}

      assert ChangeTransitions.detect(
               prior,
               pr(state: :closed, merged_at: ~U[2026-04-23 10:00:00Z])
             ) == []
    end

    test "no state or sha change returns []" do
      prior = %{state: :open, head_sha: "sha"}
      assert ChangeTransitions.detect(prior, pr(state: :open)) == []
    end

    test "draft → open with same sha returns []" do
      prior = %{state: :draft, head_sha: "sha"}
      assert ChangeTransitions.detect(prior, pr(state: :open)) == []
    end

    test "merge already in DB stays put (idempotent)" do
      prior = %{state: :merged, head_sha: "sha"}

      assert ChangeTransitions.detect(
               prior,
               pr(state: :merged, merged_at: ~U[2026-04-23 10:00:00Z])
             ) == []
    end
  end
end

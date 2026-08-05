defmodule Tracker.Nixpkgs.ChangeTransitionsTest do
  use Tracker.DataCase, async: true

  import Tracker.Fixtures

  alias Tracker.Accounts.User
  alias Tracker.GitHub.GraphQL.PullRequest
  alias Tracker.Notifications.ChangeSubscription
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

  describe "emit/2 auto-subscribes the merger" do
    test "subscribes an opted-in merger on :merged" do
      user = register_user!(%{"id" => 8001})
      User.set_auto_subscribe!(user, %{auto_subscribe_merged_changes: true}, actor: user)
      change = change!(nil, %{merged_by_github_id: 8001})

      assert :ok = ChangeTransitions.emit(change, :merged)

      assert [%{change_id: change_id, channel_id: nil}] =
               ChangeSubscription.for_user!(actor: user)

      assert change_id == change.id
    end

    test "does not subscribe a merger who has not opted in" do
      user = register_user!(%{"id" => 8002})
      change = change!(nil, %{merged_by_github_id: 8002})

      assert :ok = ChangeTransitions.emit(change, :merged)

      assert [] = ChangeSubscription.for_user!(actor: user)
    end

    test "other transitions do not subscribe anyone" do
      user = register_user!(%{"id" => 8003})
      User.set_auto_subscribe!(user, %{auto_subscribe_merged_changes: true}, actor: user)
      change = change!(nil, %{state: :open, merged_by_github_id: 8003})

      assert :ok = ChangeTransitions.emit(change, :head_sha_changed)

      assert [] = ChangeSubscription.for_user!(actor: user)
    end
  end
end

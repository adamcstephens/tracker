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

  test "a completed retarget refresh does not suppress another retarget" do
    change = change!(nil, %{state: :open})
    assert :ok = ChangeTransitions.emit(change, :base_ref_changed)
    assert [job] = all_enqueued(worker: Tracker.Nixpkgs.ChangeArtifactRefreshWorker)

    job
    |> Ecto.Changeset.change(state: "completed")
    |> Tracker.Repo.update!()

    assert :ok = ChangeTransitions.emit(change, :base_ref_changed)
    assert [_job] = all_enqueued(worker: Tracker.Nixpkgs.ChangeArtifactRefreshWorker)
  end

  describe "detect/2" do
    test "retargeting open and draft changes reconciles without a head change" do
      for state <- [:open, :draft],
          {old_base, new_base} <- [{"master", "staging"}, {"staging", "master"}] do
        prior = pr(state: state, base_ref: old_base)

        assert ChangeTransitions.detect(prior, pr(state: state, base_ref: new_base)) ==
                 [:base_ref_changed]
      end
    end

    test "simultaneous head and base changes enqueue only a head refresh" do
      prior = pr(head_sha: "old", base_ref: "master")

      assert ChangeTransitions.detect(
               prior,
               pr(head_sha: "new", base_ref: "staging")
             ) == [:head_sha_changed]
    end

    test "terminal transitions take precedence over retargeting" do
      prior = pr(base_ref: "master")

      assert ChangeTransitions.detect(prior, pr(state: :merged, base_ref: "staging")) ==
               [:merged]

      assert ChangeTransitions.detect(prior, pr(state: :closed, base_ref: "staging")) ==
               [:closed_no_merge]
    end

    test "open → merged emits :merged" do
      prior = pr(state: :open)

      assert ChangeTransitions.detect(
               prior,
               pr(state: :merged, merged_at: ~U[2026-04-23 10:00:00Z])
             ) ==
               [:merged]
    end

    test "draft → merged emits :merged" do
      prior = pr(state: :draft)

      assert ChangeTransitions.detect(
               prior,
               pr(state: :merged, merged_at: ~U[2026-04-23 10:00:00Z])
             ) ==
               [:merged]
    end

    test "open with head_sha change emits :head_sha_changed" do
      prior = pr(state: :open, head_sha: "old")

      assert ChangeTransitions.detect(prior, pr(state: :open, head_sha: "new")) ==
               [:head_sha_changed]
    end

    test "draft with head_sha change emits :head_sha_changed" do
      prior = pr(state: :draft, head_sha: "old")

      assert ChangeTransitions.detect(prior, pr(state: :draft, head_sha: "new")) ==
               [:head_sha_changed]
    end

    test "open → closed without merge emits :closed_no_merge" do
      prior = pr(state: :open)

      assert ChangeTransitions.detect(prior, pr(state: :closed, merged_at: nil)) ==
               [:closed_no_merge]
    end

    test "draft → closed without merge emits :closed_no_merge" do
      prior = pr(state: :draft)

      assert ChangeTransitions.detect(prior, pr(state: :closed, merged_at: nil)) ==
               [:closed_no_merge]
    end

    test "open → closed with merged_at set does not emit :closed_no_merge" do
      prior = pr(state: :open)

      assert ChangeTransitions.detect(
               prior,
               pr(state: :closed, merged_at: ~U[2026-04-23 10:00:00Z])
             ) == []
    end

    test "no state or sha change returns []" do
      prior = pr(state: :open)
      assert ChangeTransitions.detect(prior, pr(state: :open)) == []
    end

    test "draft → open with same sha returns []" do
      prior = pr(state: :draft)
      assert ChangeTransitions.detect(prior, pr(state: :open)) == []
    end

    test "merge already in DB stays put (idempotent)" do
      prior = pr(state: :merged)

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

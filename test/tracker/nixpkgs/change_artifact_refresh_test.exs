defmodule Tracker.Nixpkgs.ChangeArtifactRefreshTest do
  use Tracker.DataCase, async: true

  alias Tracker.Accounts.User
  alias Tracker.Nixpkgs.Change
  alias Tracker.Nixpkgs.ChangeArtifactRefresh
  alias Tracker.Nixpkgs.ChangeArtifactRefreshWorker

  setup do
    Change.bulk_upsert_all([
      %{
        number: 46_800,
        title: "diagnostic change",
        state: :merged,
        author: "author",
        url: "https://github.com/NixOS/nixpkgs/pull/46800",
        base_ref: "master",
        processing_status: :failed
      }
    ])

    %{change: Change.get_by_number!(46_800)}
  end

  test "loads the latest refresh job with diagnostic details", %{change: change} do
    now = DateTime.utc_now()

    %{"number" => change.number, "reason" => "merged"}
    |> ChangeArtifactRefreshWorker.new()
    |> Ecto.Changeset.change(
      state: "discarded",
      attempt: 10,
      errors: [%{"attempt" => 10, "at" => now, "error" => "secret upstream response"}],
      attempted_at: now,
      discarded_at: now,
      inserted_at: DateTime.add(now, -10, :second)
    )
    |> Repo.insert!()

    latest =
      %{
        "number" => change.number,
        "reason" => "merged",
        "initiated_by_user_id" => "0199-admin",
        "initiated_by_github_username" => "operator"
      }
      |> ChangeArtifactRefreshWorker.new()
      |> Ecto.Changeset.change(inserted_at: now)
      |> Repo.insert!()

    assert %ChangeArtifactRefresh.Diagnostics{
             id: id,
             reason: "merged",
             state: "available",
             attempt: 0,
             max_attempts: 10,
             inserted_at: ^now,
             initiated_by_user_id: "0199-admin",
             initiated_by_github_username: "operator",
             raw_error: nil,
             incomplete?: true
           } = ChangeArtifactRefresh.latest(change.number)

    assert id == latest.id
  end

  test "rejects retries from non-administrators", %{change: change} do
    actor = %User{id: Ecto.UUID.generate(), github_username: "member", roles: [:user]}

    assert {:error, :forbidden} = ChangeArtifactRefresh.retry(change, actor)
    refute_enqueued(worker: ChangeArtifactRefreshWorker)
  end

  test "enqueues one administrator retry and reports the matching incomplete job", %{
    change: change
  } do
    actor = %User{id: Ecto.UUID.generate(), github_username: "operator", roles: [:user, :admin]}

    assert {:ok, :enqueued, first} = ChangeArtifactRefresh.retry(change, actor)
    assert {:ok, :existing, second} = ChangeArtifactRefresh.retry(change, actor)
    assert first.id == second.id

    assert_enqueued(
      worker: ChangeArtifactRefreshWorker,
      args: %{
        "number" => change.number,
        "reason" => "merged",
        "initiated_by_user_id" => actor.id,
        "initiated_by_github_username" => actor.github_username
      }
    )

    assert [_job] = all_enqueued(worker: ChangeArtifactRefreshWorker)
  end

  for state <- [:open, :draft] do
    test "uses head_sha_changed when retrying a #{state} change" do
      state = unquote(state)
      number = 46_810 + System.unique_integer([:positive])

      Change.bulk_upsert_all([
        %{
          number: number,
          title: "#{state} change",
          state: state,
          author: "author",
          url: "https://github.com/NixOS/nixpkgs/pull/#{number}",
          base_ref: "master"
        }
      ])

      actor = %User{id: Ecto.UUID.generate(), github_username: "operator", roles: [:admin]}

      assert {:ok, :enqueued, diagnostics} =
               number |> Change.get_by_number!() |> ChangeArtifactRefresh.retry(actor)

      assert diagnostics.reason == "head_sha_changed"
    end
  end
end

defmodule Tracker.Nixpkgs.CommitterSyncWorkerTest do
  use Tracker.DataCase, async: true

  alias Tracker.Nixpkgs.{CommitterSyncWorker, Maintainer}

  test "matches direct member files case-insensitively without creating missing maintainers" do
    Maintainer.bulk_upsert_all([
      %{github_id: 1, github: "Alice"},
      %{github_id: 2, github: "bob"},
      %{github_id: 3}
    ])

    assert {:ok, 1} =
             sync(["members/aLiCe", "members/missing", "members/bob/nested", "README.md"])

    assert classifications() == %{1 => true, 2 => false, 3 => false}
  end

  test "reconciles additions and removals and leaves unchanged rows untouched" do
    Maintainer.bulk_upsert_all([
      %{github_id: 1, github: "alice"},
      %{github_id: 2, github: "bob"}
    ])

    assert {:ok, 1} = sync(["members/alice"])
    assert {:ok, 2} = sync(["members/bob"])
    assert classifications() == %{1 => false, 2 => true}

    before = Maintainer.read!()
    assert {:ok, 0} = sync(["members/bob"])
    assert Maintainer.read!() == before

    assert {:ok, 1} = sync([])
    assert classifications() == %{1 => false, 2 => false}
  end

  test "metadata upserts preserve the independently managed classification" do
    Maintainer.bulk_upsert_all([%{github_id: 1, github: "alice"}])
    assert {:ok, 1} = sync(["members/alice"])

    Maintainer.bulk_upsert_all([%{github_id: 1, github: "Alice"}])

    assert %{github: "Alice", committer: true} = Maintainer.get_by_github_id!(1)
  end

  test "fetch failures preserve all previously stored classifications" do
    Maintainer.bulk_upsert_all([
      %{github_id: 1, github: "alice"},
      %{github_id: 2, github: "bob"}
    ])

    assert {:ok, 1} = sync(["members/alice"])
    before = Maintainer.read!()

    for reason <- [:truncated_tree, :invalid_tree, %GitHub.Error{code: 503}] do
      assert {:error, ^reason} = CommitterSyncWorker.run(fetch: fn -> {:error, reason} end)
      assert Maintainer.read!() == before
    end
  end

  defp sync(files), do: CommitterSyncWorker.run(fetch: fn -> {:ok, files} end)

  defp classifications do
    Map.new(Maintainer.read!(), &{&1.github_id, &1.committer})
  end
end

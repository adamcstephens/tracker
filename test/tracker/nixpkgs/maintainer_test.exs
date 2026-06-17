defmodule Tracker.Nixpkgs.MaintainerTest do
  use Tracker.DataCase, async: true

  require Ash.Query

  alias Tracker.Nixpkgs.Maintainer

  defp by_handle(handle) do
    Maintainer
    |> Ash.Query.filter(github == ^handle)
    |> Ash.read!()
  end

  defp by_github_id(github_id) do
    Maintainer
    |> Ash.Query.filter(github_id == ^github_id)
    |> Ash.read!()
  end

  describe "bulk_upsert_all/1" do
    test "inserts new maintainers" do
      Maintainer.bulk_upsert_all([
        %{github_id: 1, github: "alice"},
        %{github_id: 2, github: "bob"}
      ])

      assert [%{github: "alice"}] = by_github_id(1)
      assert [%{github: "bob"}] = by_github_id(2)
    end

    test "updates the handle in place when github_id is stable" do
      Maintainer.bulk_upsert_all([%{github_id: 1, github: "old-handle"}])
      [%{id: id}] = by_github_id(1)

      Maintainer.bulk_upsert_all([%{github_id: 1, github: "new-handle"}])

      assert [%{id: ^id, github: "new-handle"}] = by_github_id(1)
      assert [] = by_handle("old-handle")
    end

    test "reassigns github_id in place when a handle moves to a new id" do
      # nixpkgs corrects a maintainer's githubId while keeping the handle.
      Maintainer.bulk_upsert_all([%{github_id: 153_073_356, github: "0xSA7"}])
      [%{id: original_id}] = by_handle("0xSA7")

      Maintainer.bulk_upsert_all([%{github_id: 109_046_494, github: "0xSA7"}])

      # Exactly one row holds the handle, the same PK as before (FKs preserved),
      # now carrying the corrected github_id. The stale id is gone.
      assert [%{id: ^original_id, github_id: 109_046_494}] = by_handle("0xSA7")
      assert [] = by_github_id(153_073_356)
    end

    test "siblings in the same batch are still upserted when a handle moves" do
      Maintainer.bulk_upsert_all([%{github_id: 153_073_356, github: "0xSA7"}])

      Maintainer.bulk_upsert_all([
        %{github_id: 109_046_494, github: "0xSA7"},
        %{github_id: 52_875_777, github: "ChanningHe"}
      ])

      assert [%{github_id: 109_046_494}] = by_handle("0xSA7")
      assert [%{github_id: 52_875_777}] = by_handle("ChanningHe")
    end
  end
end

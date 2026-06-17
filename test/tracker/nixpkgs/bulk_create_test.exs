defmodule Tracker.Nixpkgs.BulkCreateTest do
  use Tracker.DataCase, async: true

  alias Tracker.Nixpkgs.TeamMember

  describe "bulk helpers surface errors" do
    test "raises when a batch hits a constraint violation instead of swallowing it" do
      # team_id / maintainer_id reference non-existent rows -> FK violation.
      assert_raise RuntimeError, ~r/failed/, fn ->
        TeamMember.bulk_create_all([%{team_id: 999_999_999, maintainer_id: 999_999_999}])
      end
    end
  end
end

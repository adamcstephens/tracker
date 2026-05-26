defmodule Mix.Tasks.Tracker.ApiTokenTest do
  use Tracker.DataCase, async: true

  alias Mix.Tasks.Tracker.ApiToken
  alias Mix.Tasks.Tracker.ServiceAccount
  alias Tracker.Accounts.User

  describe "Issue.parse!/1" do
    test "extracts known switches" do
      opts =
        ApiToken.Issue.parse!([
          "--actor",
          "alice",
          "--user",
          "bob",
          "--expires-in",
          "60",
          "--label",
          "ci"
        ])

      assert opts[:actor] == "alice"
      assert opts[:user] == "bob"
      assert opts[:expires_in] == 60
      assert opts[:label] == "ci"
    end

    test "raises when --actor is missing" do
      assert_raise Mix.Error, ~r/missing required --actor/, fn ->
        ApiToken.Issue.parse!(["--user", "bob"])
      end
    end
  end

  describe "Revoke.parse!/1" do
    test "raises when --jti is missing" do
      assert_raise Mix.Error, ~r/missing required --jti/, fn ->
        ApiToken.Revoke.parse!(["--actor", "alice"])
      end
    end
  end

  describe "ServiceAccount.Create.parse!/1" do
    test "raises when --roles is missing" do
      assert_raise Mix.Error, ~r/missing required --roles/, fn ->
        ServiceAccount.Create.parse!(["--actor", "alice", "--name", "ingest"])
      end
    end
  end

  describe "Support.fetch_user_by_github_username!/1" do
    test "returns the matching user" do
      user = register_via_github!()

      found =
        Mix.Tasks.Tracker.ApiToken.Support.fetch_user_by_github_username!(user.github_username)

      assert found.id == user.id
    end

    test "raises when no user matches" do
      assert_raise Mix.Error, ~r/no user found/, fn ->
        Mix.Tasks.Tracker.ApiToken.Support.fetch_user_by_github_username!("does-not-exist")
      end
    end
  end

  defp register_via_github!(overrides \\ %{}) do
    user_info =
      Map.merge(
        %{
          "id" => System.unique_integer([:positive]),
          "login" => "user_#{System.unique_integer([:positive])}"
        },
        overrides
      )

    User
    |> Ash.Changeset.for_create(:register_with_github,
      user_info: user_info,
      oauth_tokens: %{"access_token" => "tok"}
    )
    |> Ash.create!(authorize?: false)
  end
end

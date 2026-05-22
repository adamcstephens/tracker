defmodule Tracker.Accounts.UserTest do
  use Tracker.DataCase, async: true

  alias Tracker.Accounts.User

  describe "has_role?/2" do
    test "returns true when role is present" do
      user = %User{roles: [:user, :admin]}

      assert User.has_role?(user, :user)
      assert User.has_role?(user, :admin)
    end

    test "returns false when role is absent" do
      user = %User{roles: [:user]}

      refute User.has_role?(user, :admin)
      refute User.has_role?(user, :maintainer)
    end
  end

  describe "register_with_github" do
    test "defaults roles to [:user]" do
      user = register_via_github!()

      assert user.roles == [:user]
    end

    test "re-registering the same github user preserves existing roles" do
      user_info = %{"id" => 1001, "login" => "octocat"}
      register_via_github!(user_info)

      Tracker.Repo.update_all("users", set: [roles: ["user", "admin"]])

      reregistered = register_via_github!(user_info)

      assert Enum.sort(reregistered.roles) == [:admin, :user]
    end
  end

  describe "roles invariants" do
    test "duplicates collapse to a unique list" do
      user =
        User
        |> Ash.Changeset.for_create(:register_with_github,
          user_info: %{"id" => 42, "login" => "octocat"},
          oauth_tokens: %{"access_token" => "tok"}
        )
        |> Ash.Changeset.force_change_attribute(:roles, [:admin, :user, :admin])
        |> Ash.create!(authorize?: false)

      assert Enum.sort(user.roles) == [:admin, :user]
    end

    test "empty roles list is rejected" do
      assert_raise Ash.Error.Invalid, fn ->
        User
        |> Ash.Changeset.for_create(:register_with_github,
          user_info: %{"id" => 43, "login" => "hubot"},
          oauth_tokens: %{"access_token" => "tok"}
        )
        |> Ash.Changeset.force_change_attribute(:roles, [])
        |> Ash.create!(authorize?: false)
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

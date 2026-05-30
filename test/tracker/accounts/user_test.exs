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

    test "accepts :reconstruction_worker as a valid role" do
      user = %User{roles: [:reconstruction_worker]}

      assert User.has_role?(user, :reconstruction_worker)
      assert :reconstruction_worker in Tracker.Accounts.User.Role.values()
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

  describe "create_service_account" do
    test "admin can create a service account with given roles" do
      admin = register_via_github!() |> with_roles!([:user, :admin])

      service = User.create_service_account!("ingest", [:user, :maintainer], actor: admin)

      assert service.github_username == "service:ingest"
      assert service.github_id == nil
      assert Enum.sort(service.roles) == [:maintainer, :user]
    end

    test "non-admin actor is forbidden" do
      non_admin = register_via_github!()

      assert_raise Ash.Error.Forbidden, fn ->
        User.create_service_account!("ingest", [:user], actor: non_admin)
      end
    end

    test "duplicate service-account names are rejected" do
      admin = register_via_github!() |> with_roles!([:admin])

      User.create_service_account!("dupe", [:user], actor: admin)

      assert_raise Ash.Error.Invalid, fn ->
        User.create_service_account!("dupe", [:user], actor: admin)
      end
    end
  end

  describe "live_ui preference" do
    test "defaults to true on registration" do
      user = register_via_github!()

      assert user.live_ui == true
    end

    test "set_live_ui flips the preference" do
      user = register_via_github!()

      updated = User.set_live_ui!(user, %{live_ui: false}, actor: user)

      assert updated.live_ui == false
    end

    test "set_live_ui forbids another user from changing your preference" do
      user = register_via_github!()
      other = register_via_github!()

      assert_raise Ash.Error.Forbidden, fn ->
        User.set_live_ui!(user, %{live_ui: false}, actor: other)
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

  defp with_roles!(%User{} = user, roles) do
    role_strings = Enum.map(roles, &Atom.to_string/1)

    Tracker.Repo.update_all(
      from(u in "users", where: u.github_id == ^user.github_id),
      set: [roles: role_strings]
    )

    Ash.get!(User, user.id, authorize?: false)
  end
end

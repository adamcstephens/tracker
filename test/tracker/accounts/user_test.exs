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

  describe "issue_api_token" do
    test "user can issue a token for themselves" do
      user = register_via_github!()

      assert {:ok, %{token: token, jti: jti, expires_at: %DateTime{} = expires_at}} =
               User.issue_api_token(user.id, %{expires_in: 3600, label: "ci"}, actor: user)

      assert is_binary(token)
      assert byte_size(jti) > 0
      assert DateTime.diff(expires_at, DateTime.utc_now()) in 3500..3700

      {:ok, claims, Tracker.Accounts.User} =
        AshAuthentication.Jwt.verify(token, :tracker)

      assert claims["purpose"] == "api"
      assert claims["sub"] =~ "user?id=#{user.id}"
      assert claims["jti"] == jti

      require Ash.Query

      record =
        Tracker.Accounts.Token
        |> Ash.Query.filter(jti == ^jti)
        |> Ash.read_one!(authorize?: false)

      assert record.purpose == "api"
      assert record.extra_data["label"] == "ci"
    end

    test "admin can issue a token for a service account" do
      admin = register_via_github!() |> with_roles!([:admin])
      service = User.create_service_account!("ingest", [:user], actor: admin)

      assert {:ok, %{token: token}} =
               User.issue_api_token(service.id, %{expires_in: 60}, actor: admin)

      assert {:ok, claims, _} = AshAuthentication.Jwt.verify(token, :tracker)
      assert claims["sub"] =~ "user?id=#{service.id}"
    end

    test "admin cannot issue a token for another human user" do
      admin = register_via_github!() |> with_roles!([:admin])
      other = register_via_github!()

      assert {:error, %Ash.Error.Forbidden{}} =
               User.issue_api_token(other.id, %{expires_in: 60}, actor: admin)
    end

    test "non-admin cannot issue a token for another user" do
      issuer = register_via_github!()
      other = register_via_github!()

      assert {:error, %Ash.Error.Forbidden{}} =
               User.issue_api_token(other.id, %{expires_in: 60}, actor: issuer)
    end

    test "defaults to roughly one year expiry" do
      user = register_via_github!()

      assert {:ok, %{expires_at: expires_at}} =
               User.issue_api_token(user.id, %{}, actor: user)

      diff_days = DateTime.diff(expires_at, DateTime.utc_now(), :day)
      assert diff_days in 364..366
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

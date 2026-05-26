defmodule Tracker.Accounts.TokenTest do
  use Tracker.DataCase, async: true

  alias Tracker.Accounts.{Token, User}

  describe "revoke_own_token / revoke_token_admin" do
    test "owner can revoke their own api token" do
      user = register_via_github!()
      {:ok, %{jti: jti}} = User.issue_api_token(user.id, %{}, actor: user)

      assert {:ok, _} = Token.revoke_own_token(jti, actor: user)

      assert token_revoked?(jti)
    end

    test "non-owner cannot revoke another user's api token" do
      alice = register_via_github!()
      bob = register_via_github!()
      {:ok, %{jti: jti}} = User.issue_api_token(alice.id, %{}, actor: alice)

      assert {:error, %Ash.Error.Forbidden{}} = Token.revoke_own_token(jti, actor: bob)
    end

    test "admin can revoke any api token via the admin interface" do
      user = register_via_github!()
      admin = register_via_github!() |> with_roles!([:admin])
      {:ok, %{jti: jti}} = User.issue_api_token(user.id, %{}, actor: user)

      assert {:ok, _} = Token.revoke_token_admin(jti, actor: admin)

      assert token_revoked?(jti)
    end
  end

  defp token_revoked?(jti) do
    {:ok, result} =
      Token
      |> Ash.ActionInput.for_action(:revoked?, %{jti: jti})
      |> Ash.ActionInput.set_context(%{private: %{ash_authentication?: true}})
      |> Ash.run_action()

    result
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

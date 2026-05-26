defmodule Tracker.Accounts.ApiTokenTest do
  use Tracker.DataCase, async: true

  alias Tracker.Accounts.{ApiToken, User}

  describe "issue" do
    test "user issues a token for themselves" do
      user = register_via_github!()

      assert {:ok, %{token: jwt, jti: jti, expires_at: %DateTime{}}} =
               ApiToken.issue(user.id, %{label: "ci", expires_in: 3600}, actor: user)

      assert is_binary(jwt)
      {:ok, claims, _} = AshAuthentication.Jwt.verify(jwt, :tracker)
      assert claims["purpose"] == "api"
      assert claims["jti"] == jti

      {:ok, row} = ApiToken.get_by_jti(jti)
      assert row.label == "ci"
      assert row.subject_user_id == user.id
      assert row.issued_by_user_id == user.id
      assert row.revoked_at == nil
    end

    test "admin issues for a service account" do
      admin = register_via_github!() |> with_roles!([:admin])
      service = User.create_service_account!("ingest", [:user], actor: admin)

      assert {:ok, %{jti: jti}} = ApiToken.issue(service.id, %{}, actor: admin)

      {:ok, row} = ApiToken.get_by_jti(jti)
      assert row.subject_user_id == service.id
      assert row.issued_by_user_id == admin.id
    end

    test "admin cannot issue for another human user" do
      admin = register_via_github!() |> with_roles!([:admin])
      other = register_via_github!()

      assert {:error, %Ash.Error.Forbidden{}} =
               ApiToken.issue(other.id, %{}, actor: admin)
    end

    test "non-admin cannot issue for another user" do
      issuer = register_via_github!()
      other = register_via_github!()

      assert {:error, %Ash.Error.Forbidden{}} =
               ApiToken.issue(other.id, %{}, actor: issuer)
    end
  end

  describe "revoke" do
    test "owner can revoke their own token" do
      user = register_via_github!()
      {:ok, %{jti: jti}} = ApiToken.issue(user.id, %{}, actor: user)

      assert {:ok, row} = ApiToken.revoke(jti, actor: user)
      assert %DateTime{} = row.revoked_at
      assert row.revoked_by_user_id == user.id
      assert ApiToken.revoked?(row)
    end

    test "non-owner cannot revoke" do
      alice = register_via_github!()
      bob = register_via_github!()
      {:ok, %{jti: jti}} = ApiToken.issue(alice.id, %{}, actor: alice)

      assert {:error, %Ash.Error.Forbidden{}} = ApiToken.revoke(jti, actor: bob)
    end

    test "admin can revoke a service-account token" do
      admin = register_via_github!() |> with_roles!([:admin])
      service = User.create_service_account!("ingest", [:user], actor: admin)
      {:ok, %{jti: jti}} = ApiToken.issue(service.id, %{}, actor: admin)

      assert {:ok, row} = ApiToken.revoke(jti, actor: admin)
      assert ApiToken.revoked?(row)
      assert row.revoked_by_user_id == admin.id
    end

    test "admin cannot revoke another human user's token" do
      admin = register_via_github!() |> with_roles!([:admin])
      other = register_via_github!()
      {:ok, %{jti: jti}} = ApiToken.issue(other.id, %{}, actor: other)

      assert {:error, %Ash.Error.Forbidden{}} = ApiToken.revoke(jti, actor: admin)
    end
  end

  describe "list_for_actor" do
    test "lists the actor's own tokens, newest first" do
      user = register_via_github!()
      {:ok, %{jti: a}} = ApiToken.issue(user.id, %{label: "first"}, actor: user)
      {:ok, %{jti: b}} = ApiToken.issue(user.id, %{label: "second"}, actor: user)

      rows = ApiToken.list_for_actor!(actor: user)

      assert Enum.map(rows, & &1.jti) == [b, a]
    end

    test "another user's tokens are not visible" do
      alice = register_via_github!()
      bob = register_via_github!()
      {:ok, _} = ApiToken.issue(alice.id, %{}, actor: alice)

      assert ApiToken.list_for_actor!(actor: bob) == []
    end
  end

  describe "isolation from AshAuthentication's tokens table" do
    test "revoke_all_stored_for_subject on the session tokens does not revoke api tokens" do
      user = register_via_github!()
      {:ok, %{jti: api_jti}} = ApiToken.issue(user.id, %{label: "robot"}, actor: user)
      subject = AshAuthentication.user_to_subject(user)

      %Ash.BulkResult{status: :success} =
        Tracker.Accounts.Token
        |> Ash.bulk_update(:revoke_all_stored_for_subject, %{subject: subject},
          authorize?: false,
          context: %{private: %{ash_authentication?: true}}
        )

      {:ok, row} = ApiToken.get_by_jti(api_jti)
      assert row.revoked_at == nil
    end
  end

  describe "touch_last_used_at" do
    test "updates last_used_at on an existing token" do
      user = register_via_github!()
      {:ok, %{jti: jti}} = ApiToken.issue(user.id, %{}, actor: user)

      assert {:ok, row} = ApiToken.touch_last_used_at(jti)
      assert %DateTime{} = row.last_used_at
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

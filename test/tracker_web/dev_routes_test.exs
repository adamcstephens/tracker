defmodule TrackerWeb.DevRoutesTest do
  use TrackerWeb.ConnCase, async: true

  import Ecto.Query

  alias AshAuthentication.Plug.Helpers
  alias Tracker.Accounts.User

  @dev_paths ["/dev/dashboard", "/dev/mailbox", "/dev/oban"]

  describe "anonymous users" do
    test "are redirected to sign-in", %{conn: conn} do
      for path <- @dev_paths do
        conn = get(conn, path)

        assert redirected_to(conn) == ~p"/sign-in", "expected #{path} to redirect to sign-in"
      end
    end
  end

  describe "non-admin users" do
    test "are redirected home", %{conn: conn} do
      user = register_via_github!()
      refute User.has_role?(user, :admin)

      for path <- @dev_paths do
        conn = conn |> log_in(user) |> get(path)

        assert redirected_to(conn) == ~p"/", "expected #{path} to redirect home"
      end
    end
  end

  describe "admin users" do
    test "can access the live dashboard", %{conn: conn} do
      conn = conn |> log_in(admin!()) |> get(~p"/dev/dashboard")

      assert redirected_to(conn) =~ "/dev/dashboard/"
    end

    test "can access the mailbox preview", %{conn: conn} do
      conn = conn |> log_in(admin!()) |> get(~p"/dev/mailbox")

      assert conn.status in [200, 302]
      refute redirected_to_auth?(conn)
    end

    test "reach the oban dashboard mount", %{conn: conn} do
      # Oban.Met doesn't run in the test env, so the dashboard itself can't
      # render; raising from its mount still proves the request cleared the
      # admin gate instead of being redirected.
      assert_raise RuntimeError, ~r/no config registered/, fn ->
        conn |> log_in(admin!()) |> get(~p"/dev/oban")
      end
    end
  end

  defp redirected_to_auth?(%{status: 302} = conn) do
    redirected_to(conn) in [~p"/sign-in", ~p"/"]
  end

  defp redirected_to_auth?(_conn), do: false

  defp admin! do
    user = register_via_github!()

    Tracker.Repo.update_all(
      from(u in "users", where: u.github_id == ^user.github_id),
      set: [roles: ["user", "admin"]]
    )

    # Re-register with the same identity so the returned user carries both
    # the updated roles and the session token metadata store_in_session needs.
    register_via_github!(%{"id" => user.github_id, "login" => user.github_username})
  end

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Helpers.store_in_session(user)
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

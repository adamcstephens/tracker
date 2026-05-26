defmodule TrackerWeb.AccountLive.TokensTest do
  use TrackerWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias AshAuthentication.Plug.Helpers
  alias Tracker.Accounts.{Token, User}

  describe "non-admin user" do
    test "redirects to sign-in when not logged in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/account/tokens")
    end

    test "lists own tokens", %{conn: conn} do
      user = register_via_github!()
      {:ok, _} = User.issue_api_token(user.id, %{label: "my-ci"}, actor: user)
      conn = log_in(conn, user)

      {:ok, _view, html} = live(conn, ~p"/account/tokens")

      assert html =~ "my-ci"
      assert html =~ "active"
    end

    test "issues a token and shows the JWT once", %{conn: conn} do
      user = register_via_github!()
      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/account/tokens")

      view
      |> form("#issue-form", token: %{label: "deploy", expires_in_days: "30"})
      |> render_submit()

      assert has_element?(view, "#fresh-token")
      jwt = view |> element("#fresh-token-value") |> render() |> strip_tags()
      assert String.starts_with?(jwt, "eyJ")

      assert {:ok, _claims, _} = AshAuthentication.Jwt.verify(jwt, :tracker)
    end

    test "dismissing the fresh token hides it", %{conn: conn} do
      user = register_via_github!()
      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/account/tokens")

      view
      |> form("#issue-form", token: %{label: "x", expires_in_days: "30"})
      |> render_submit()

      assert has_element?(view, "#fresh-token")

      view |> element("button", "Dismiss") |> render_click()

      refute has_element?(view, "#fresh-token")
    end

    test "revokes own token", %{conn: conn} do
      user = register_via_github!()
      {:ok, %{jti: jti}} = User.issue_api_token(user.id, %{label: "x"}, actor: user)
      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/account/tokens")

      view
      |> element("button[phx-value-jti='#{jti}']")
      |> render_click()

      html = render(view)
      assert html =~ "revoked"
    end

    test "does not show the service-account selector", %{conn: conn} do
      user = register_via_github!()
      conn = log_in(conn, user)

      {:ok, _view, html} = live(conn, ~p"/account/tokens")

      refute html =~ "Viewing tokens for"
    end
  end

  describe "admin user" do
    test "sees the service-account selector when service accounts exist", %{conn: conn} do
      admin = register_via_github!() |> grant_admin!()
      _service = User.create_service_account!("ingest", [:user], actor: admin)
      conn = log_in(conn, admin)

      {:ok, _view, html} = live(conn, ~p"/account/tokens")

      assert html =~ "Viewing tokens for"
      assert html =~ "service:ingest"
    end

    test "can switch to a service account and issue a token for it", %{conn: conn} do
      admin = register_via_github!() |> grant_admin!()
      service = User.create_service_account!("ingest", [:user], actor: admin)
      conn = log_in(conn, admin)

      {:ok, view, _html} = live(conn, ~p"/account/tokens")

      view
      |> form("form[phx-change='select_user']", user_id: service.id)
      |> render_change()

      view
      |> form("#issue-form", token: %{label: "robot", expires_in_days: "7"})
      |> render_submit()

      assert has_element?(view, "#fresh-token")

      subject = AshAuthentication.user_to_subject(service)
      rows = Token.list_api_tokens_for_subject!(subject, actor: admin)
      assert Enum.any?(rows, fn r -> r.extra_data["label"] == "robot" end)
    end

    test "can revoke a service-account token via the row action", %{conn: conn} do
      admin = register_via_github!() |> grant_admin!()
      service = User.create_service_account!("ingest", [:user], actor: admin)
      {:ok, %{jti: jti}} = User.issue_api_token(service.id, %{label: "robot"}, actor: admin)
      conn = log_in(conn, admin)

      {:ok, view, _html} = live(conn, ~p"/account/tokens")

      view
      |> form("form[phx-change='select_user']", user_id: service.id)
      |> render_change()

      view
      |> element("button[phx-value-jti='#{jti}']")
      |> render_click()

      html = render(view)
      assert html =~ "revoked"
    end
  end

  defp log_in(conn, user) do
    conn
    |> init_test_session(%{})
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

  defp grant_admin!(%User{} = user) do
    Tracker.Repo.update_all(
      from(u in "users", where: u.github_id == ^user.github_id),
      set: [roles: ["user", "admin"]]
    )

    refreshed = Ash.get!(User, user.id, authorize?: false)
    %{refreshed | __metadata__: user.__metadata__}
  end

  defp strip_tags(html) do
    html
    |> String.replace(~r/<[^>]+>/, "")
    |> String.trim()
  end
end

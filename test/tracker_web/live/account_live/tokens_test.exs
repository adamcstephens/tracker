defmodule TrackerWeb.AccountLive.TokensTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias AshAuthentication.Plug.Helpers
  alias Tracker.Accounts.{ApiToken, User}

  describe "/account/tokens" do
    test "redirects to sign-in when not logged in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/account/tokens")
    end

    test "lists the user's own active tokens", %{conn: conn} do
      user = register_via_github!()
      {:ok, _} = ApiToken.issue(user.id, %{label: "my-ci"}, actor: user)
      conn = log_in(conn, user)

      {:ok, _view, html} = live(conn, ~p"/account/tokens")

      assert html =~ "my-ci"
      assert html =~ "active"
    end

    test "does not list revoked user-session tokens from prior logouts", %{conn: conn} do
      user = register_via_github!()
      _ = simulate_logged_out_session(user)

      conn = log_in(conn, user)

      {:ok, _view, html} = live(conn, ~p"/account/tokens")

      refute html =~ "revoked"
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
      assert String.starts_with?(jwt, ApiToken.token_prefix())

      raw = String.replace_prefix(jwt, ApiToken.token_prefix(), "")
      assert {:ok, _claims, _} = AshAuthentication.Jwt.verify(raw, :tracker)
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
      {:ok, %{jti: jti}} = ApiToken.issue(user.id, %{label: "x"}, actor: user)
      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/account/tokens")

      view
      |> element("button[phx-value-jti='#{jti}']")
      |> render_click()

      html = render(view)
      assert html =~ "revoked"
    end
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

  defp simulate_logged_out_session(%User{} = user) do
    subject = AshAuthentication.user_to_subject(user)
    jti = "session-" <> Integer.to_string(System.unique_integer([:positive]))
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Tracker.Repo.insert_all("tokens", [
      %{
        jti: jti,
        subject: subject,
        purpose: "revocation",
        expires_at: now |> DateTime.add(86_400, :second) |> DateTime.truncate(:second),
        extra_data: nil,
        inserted_at: now,
        updated_at: now,
        created_at: now
      }
    ])

    jti
  end

  defp strip_tags(html) do
    html
    |> String.replace(~r/<[^>]+>/, "")
    |> String.trim()
  end
end

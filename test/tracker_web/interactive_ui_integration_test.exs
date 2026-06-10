defmodule TrackerWeb.InteractiveUIIntegrationTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias AshAuthentication.Plug.Helpers
  alias Tracker.Accounts.User

  describe "app.js script tag in the root layout" do
    test "is omitted for anonymous users", %{conn: conn} do
      conn = get(conn, ~p"/packages")

      refute html_response(conn, 200) =~ "/assets/app.js"
    end

    test "is present for an authenticated user with live_ui: true", %{conn: conn} do
      user = register_via_github!()
      conn = log_in(conn, user) |> get(~p"/packages")

      assert html_response(conn, 200) =~ "/assets/app.js"
    end

    test "is omitted for an authenticated user with live_ui: false", %{conn: conn} do
      user = register_via_github!() |> opt_out!()
      conn = log_in(conn, user) |> get(~p"/packages")

      refute html_response(conn, 200) =~ "/assets/app.js"
    end

    test "is always present on /account routes regardless of preference", %{conn: conn} do
      user = register_via_github!() |> opt_out!()
      conn = log_in(conn, user) |> get(~p"/account/tokens")

      assert html_response(conn, 200) =~ "/assets/app.js"
    end

    test "is always present on /inbox regardless of preference", %{conn: conn} do
      user = register_via_github!() |> opt_out!()
      conn = log_in(conn, user) |> get(~p"/inbox")

      assert html_response(conn, 200) =~ "/assets/app.js"
    end
  end

  describe "lens auto-submit fallback script in the root layout" do
    test "is present for anonymous users (dead view) so the dropdown auto-applies", %{conn: conn} do
      conn = get(conn, ~p"/packages")
      html = html_response(conn, 200)

      assert html =~ "requestSubmit()"
      assert html =~ ~s|matches(".lens__select")|
    end

    test "is omitted for an authenticated user with live_ui: true (phx-change drives it)",
         %{conn: conn} do
      user = register_via_github!()
      conn = log_in(conn, user) |> get(~p"/packages")

      refute html_response(conn, 200) =~ "requestSubmit()"
    end

    test "is present for an authenticated user with live_ui: false", %{conn: conn} do
      user = register_via_github!() |> opt_out!()
      conn = log_in(conn, user) |> get(~p"/packages")

      assert html_response(conn, 200) =~ "requestSubmit()"
    end
  end

  describe "slash focus-search fallback script in the root layout" do
    test "is present for anonymous users (dead view) so \"/\" focuses search", %{conn: conn} do
      conn = get(conn, ~p"/packages")
      html = html_response(conn, 200)

      assert html =~ ~s|getElementById("page-search-input")|
      assert html =~ "input.select()"
    end

    test "is omitted for an authenticated user with live_ui: true (app.js drives it)",
         %{conn: conn} do
      user = register_via_github!()
      conn = log_in(conn, user) |> get(~p"/packages")

      refute html_response(conn, 200) =~ ~s|getElementById("page-search-input")|
    end
  end

  describe "LiveView socket halts for opted-out users" do
    test "opted-out user is redirected when the socket connects", %{conn: conn} do
      user = register_via_github!() |> opt_out!()
      conn = log_in(conn, user)

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/packages")
    end

    test "opted-in user can mount a LiveView normally", %{conn: conn} do
      user = register_via_github!()
      conn = log_in(conn, user)

      {:ok, _view, html} = live(conn, ~p"/packages")
      assert html =~ "Packages"
    end

    test "anonymous user can still mount a LiveView for dead-render tests", %{conn: conn} do
      {:ok, _view, _html} = live(conn, ~p"/packages")
    end

    test "opted-out user can still mount /account/tokens", %{conn: conn} do
      user = register_via_github!() |> opt_out!()
      conn = log_in(conn, user)

      {:ok, _view, _html} = live(conn, ~p"/account/tokens")
    end

    test "opted-out user can still mount /inbox", %{conn: conn} do
      user = register_via_github!() |> opt_out!()
      conn = log_in(conn, user)

      {:ok, _view, _html} = live(conn, ~p"/inbox")
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

  defp opt_out!(user), do: User.set_live_ui!(user, %{live_ui: false}, actor: user)
end

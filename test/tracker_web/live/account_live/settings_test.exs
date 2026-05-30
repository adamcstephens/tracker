defmodule TrackerWeb.AccountLive.SettingsTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias AshAuthentication.Plug.Helpers
  alias Tracker.Accounts.User

  describe "/account/settings" do
    test "redirects to sign-in when not logged in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/account/settings")
    end

    test "shows the current live_ui preference", %{conn: conn} do
      user = register_via_github!()
      conn = log_in(conn, user)

      {:ok, _view, html} = live(conn, ~p"/account/settings")

      assert html =~ "Account settings"
      assert html =~ "checked"
    end

    test "saving with live_ui unchecked opts the user out", %{conn: conn} do
      user = register_via_github!()
      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/account/settings")

      view
      |> form("#settings-form", settings: %{live_ui: "false"})
      |> render_submit()

      reloaded = Ash.get!(User, user.id, authorize?: false)
      assert reloaded.live_ui == false
    end

    test "saving with live_ui checked opts the user back in", %{conn: conn} do
      user =
        register_via_github!()
        |> then(&User.set_live_ui!(&1, %{live_ui: false}, actor: &1))

      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/account/settings")

      view
      |> form("#settings-form", settings: %{live_ui: "true"})
      |> render_submit()

      reloaded = Ash.get!(User, user.id, authorize?: false)
      assert reloaded.live_ui == true
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
end

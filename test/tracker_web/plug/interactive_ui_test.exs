defmodule TrackerWeb.Plug.InteractiveUITest do
  use TrackerWeb.ConnCase, async: true

  alias Tracker.Accounts.User
  alias TrackerWeb.Plug.InteractiveUI

  describe "call/2" do
    test "anonymous user is not interactive" do
      conn =
        build_conn(:get, "/")
        |> Plug.Conn.assign(:current_user, nil)
        |> InteractiveUI.call([])

      assert conn.assigns.interactive? == false
    end

    test "authenticated user with live_ui: true is interactive" do
      user = register_user!(live_ui: true)

      conn =
        build_conn(:get, "/")
        |> Plug.Conn.assign(:current_user, user)
        |> InteractiveUI.call([])

      assert conn.assigns.interactive? == true
    end

    test "authenticated user with live_ui: false is not interactive" do
      user = register_user!(live_ui: false)

      conn =
        build_conn(:get, "/")
        |> Plug.Conn.assign(:current_user, user)
        |> InteractiveUI.call([])

      assert conn.assigns.interactive? == false
    end
  end

  defp register_user!(live_ui: live_ui) do
    user =
      User
      |> Ash.Changeset.for_create(:register_with_github,
        user_info: %{
          "id" => System.unique_integer([:positive]),
          "login" => "user_#{System.unique_integer([:positive])}"
        },
        oauth_tokens: %{"access_token" => "tok"}
      )
      |> Ash.create!(authorize?: false)

    User.set_live_ui!(user, %{live_ui: live_ui}, actor: user)
  end
end

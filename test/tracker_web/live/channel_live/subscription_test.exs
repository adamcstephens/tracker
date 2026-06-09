defmodule TrackerWeb.ChannelLive.SubscriptionTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tracker.Fixtures

  alias AshAuthentication.Plug.Helpers
  alias Tracker.Notifications.ChannelSubscription

  test "shows no subscribe control when logged out", %{conn: conn} do
    chan = channel!()

    {:ok, view, _html} = live(conn, ~p"/channels/#{chan.name}")

    refute has_element?(view, "#subscribe-toggle")
  end

  test "logged-in user can toggle a channel subscription", %{conn: conn} do
    user = register_user!()
    chan = channel!()
    conn = log_in(conn, user)

    {:ok, view, _html} = live(conn, ~p"/channels/#{chan.name}")

    assert has_element?(view, "#subscribe-toggle", "Subscribe")
    assert {:ok, nil} = ChannelSubscription.find(chan.id, actor: user)

    view |> element("#subscribe-toggle") |> render_click()

    assert has_element?(view, "#subscribe-toggle", "Unsubscribe")
    assert {:ok, %ChannelSubscription{}} = ChannelSubscription.find(chan.id, actor: user)

    view |> element("#subscribe-toggle") |> render_click()

    assert has_element?(view, "#subscribe-toggle", "Subscribe")
    assert {:ok, nil} = ChannelSubscription.find(chan.id, actor: user)
  end

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Helpers.store_in_session(user)
  end
end

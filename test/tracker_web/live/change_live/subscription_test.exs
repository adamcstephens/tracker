defmodule TrackerWeb.ChangeLive.SubscriptionTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tracker.Fixtures

  alias AshAuthentication.Plug.Helpers
  alias Tracker.Notifications.ChangeSubscription

  test "shows no subscribe control when logged out", %{conn: conn} do
    change = change!()

    {:ok, view, _html} = live(conn, ~p"/changes/#{change.number}")

    refute has_element?(view, "#subscribe-toggle")
  end

  test "logged-in user can toggle a change subscription", %{conn: conn} do
    user = register_user!()
    change = change!()
    conn = log_in(conn, user)

    {:ok, view, _html} = live(conn, ~p"/changes/#{change.number}")

    assert has_element?(view, "#subscribe-toggle", "Subscribe")
    assert {:ok, nil} = ChangeSubscription.find(change.id, nil, actor: user)

    view |> element("#subscribe-toggle") |> render_click()

    assert has_element?(view, "#subscribe-toggle", "Unsubscribe")
    assert {:ok, %ChangeSubscription{}} = ChangeSubscription.find(change.id, nil, actor: user)

    view |> element("#subscribe-toggle") |> render_click()

    assert has_element?(view, "#subscribe-toggle", "Subscribe")
    assert {:ok, nil} = ChangeSubscription.find(change.id, nil, actor: user)
  end

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Helpers.store_in_session(user)
  end
end

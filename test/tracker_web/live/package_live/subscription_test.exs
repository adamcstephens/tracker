defmodule TrackerWeb.PackageLive.SubscriptionTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tracker.Fixtures

  alias AshAuthentication.Plug.Helpers
  alias Tracker.Notifications.PackageSubscription

  test "shows no subscribe control when logged out", %{conn: conn} do
    pkg = package!()

    {:ok, view, _html} = live(conn, ~p"/packages/#{pkg.attribute}")

    refute has_element?(view, "#subscribe-toggle")
  end

  test "logged-in user can toggle a package subscription", %{conn: conn} do
    user = register_user!()
    pkg = package!()
    conn = log_in(conn, user)

    {:ok, view, _html} = live(conn, ~p"/packages/#{pkg.attribute}")

    assert has_element?(view, "#subscribe-toggle", "Subscribe")
    assert {:ok, nil} = PackageSubscription.find(pkg.id, nil, actor: user)

    view |> element("#subscribe-toggle") |> render_click()

    assert has_element?(view, "#subscribe-toggle", "Unsubscribe")
    assert {:ok, %PackageSubscription{}} = PackageSubscription.find(pkg.id, nil, actor: user)

    view |> element("#subscribe-toggle") |> render_click()

    assert has_element?(view, "#subscribe-toggle", "Subscribe")
    assert {:ok, nil} = PackageSubscription.find(pkg.id, nil, actor: user)
  end

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Helpers.store_in_session(user)
  end
end

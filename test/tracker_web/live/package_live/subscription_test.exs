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

  test "the event checklist appears only once subscribed", %{conn: conn} do
    user = register_user!()
    pkg = package!()
    conn = log_in(conn, user)

    {:ok, view, _html} = live(conn, ~p"/packages/#{pkg.attribute}")
    refute has_element?(view, "#subscription-events")

    view |> element("#subscribe-toggle") |> render_click()

    assert has_element?(view, "#subscription-events")
    assert has_element?(view, "input[name='events[]'][value='package_version_changed'][checked]")
    assert has_element?(view, "input[name='events[]'][value='package_change_opened']")
    refute has_element?(view, "input[name='events[]'][value='package_change_opened'][checked]")
  end

  test "checking an event persists it", %{conn: conn} do
    user = register_user!()
    pkg = package!()
    conn = log_in(conn, user)

    {:ok, view, _html} = live(conn, ~p"/packages/#{pkg.attribute}")
    view |> element("#subscribe-toggle") |> render_click()

    view
    |> form("#subscription-events")
    |> render_change(%{"events" => ["package_change_opened", "package_change_merged"]})

    {:ok, sub} = PackageSubscription.find(pkg.id, nil, actor: user)
    assert Enum.sort(sub.events) == [:package_change_merged, :package_change_opened]
    assert has_element?(view, "input[name='events[]'][value='package_change_merged'][checked]")
  end

  test "unchecking every event unsubscribes", %{conn: conn} do
    user = register_user!()
    pkg = package!()
    conn = log_in(conn, user)

    {:ok, view, _html} = live(conn, ~p"/packages/#{pkg.attribute}")
    view |> element("#subscribe-toggle") |> render_click()

    # A browser posts no `events` key at all when every box is unchecked.
    render_change(view, "set-subscription-events", %{})

    assert {:ok, nil} = PackageSubscription.find(pkg.id, nil, actor: user)
    assert has_element?(view, "#subscribe-toggle", "Subscribe")
    refute has_element?(view, "#subscription-events")
  end

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Helpers.store_in_session(user)
  end
end

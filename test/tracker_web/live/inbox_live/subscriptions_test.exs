defmodule TrackerWeb.InboxLive.SubscriptionsTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tracker.Fixtures

  alias AshAuthentication.Plug.Helpers
  alias Tracker.Notifications.ChangeSubscription
  alias Tracker.Notifications.ChannelSubscription
  alias Tracker.Notifications.PackageSubscription

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Helpers.store_in_session(user)
  end

  test "redirects a logged-out visitor to sign in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/inbox/subscriptions")
  end

  test "shows an empty state when there are no subscriptions", %{conn: conn} do
    user = register_user!()
    conn = log_in(conn, user)

    {:ok, view, _html} = live(conn, ~p"/inbox/subscriptions")

    assert has_element?(view, "#subscriptions-empty")
  end

  test "lists a package subscription scoped to a channel", %{conn: conn} do
    user = register_user!()
    package = package!()
    channel = channel!()
    sub = PackageSubscription.subscribe!(package.id, channel.id, actor: user)
    conn = log_in(conn, user)

    {:ok, view, _html} = live(conn, ~p"/inbox/subscriptions")

    assert has_element?(view, "#package-subscription-#{sub.id}", package.attribute)
    assert has_element?(view, "#package-subscription-#{sub.id}", channel.name)

    assert has_element?(
             view,
             ~s{#package-subscription-#{sub.id} a[href="/packages/#{package.attribute}"]}
           )
  end

  test "lists a package subscription for all channels", %{conn: conn} do
    user = register_user!()
    package = package!()
    sub = PackageSubscription.subscribe!(package.id, nil, actor: user)
    conn = log_in(conn, user)

    {:ok, view, _html} = live(conn, ~p"/inbox/subscriptions")

    assert has_element?(view, "#package-subscription-#{sub.id}", "All channels")
  end

  test "lists a channel subscription", %{conn: conn} do
    user = register_user!()
    channel = channel!()
    sub = ChannelSubscription.subscribe!(channel.id, actor: user)
    conn = log_in(conn, user)

    {:ok, view, _html} = live(conn, ~p"/inbox/subscriptions")

    assert has_element?(view, "#channel-subscription-#{sub.id}", channel.name)

    assert has_element?(
             view,
             ~s{#channel-subscription-#{sub.id} a[href="/channels/#{channel.name}"]}
           )
  end

  test "lists a change subscription", %{conn: conn} do
    user = register_user!()
    change = change!()
    sub = ChangeSubscription.subscribe!(change.id, nil, actor: user)
    conn = log_in(conn, user)

    {:ok, view, _html} = live(conn, ~p"/inbox/subscriptions")

    assert has_element?(view, "#change-subscription-#{sub.id}", "##{change.number}")

    assert has_element?(
             view,
             ~s{#change-subscription-#{sub.id} a[href="/changes/#{change.number}"]}
           )
  end

  test "does not show another user's subscriptions", %{conn: conn} do
    user = register_user!()
    other = register_user!()
    PackageSubscription.subscribe!(package!().id, nil, actor: other)
    conn = log_in(conn, user)

    {:ok, view, _html} = live(conn, ~p"/inbox/subscriptions")

    assert has_element?(view, "#subscriptions-empty")
  end

  describe "search" do
    test "renders an active search box", %{conn: conn} do
      user = register_user!()
      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/inbox/subscriptions")

      assert has_element?(view, "#page-search-input")
      refute has_element?(view, "#page-search-input[disabled]")
    end

    test "filters subscriptions across kinds", %{conn: conn} do
      user = register_user!()
      firefox = PackageSubscription.subscribe!(package!("firefox").id, nil, actor: user)
      chan = ChannelSubscription.subscribe!(channel!("nixos-unstable").id, actor: user)
      change = ChangeSubscription.subscribe!(change!().id, nil, actor: user)
      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/inbox/subscriptions")

      view |> element("#page-search") |> render_change(%{"search" => "FIRE"})

      assert has_element?(view, "#package-subscription-#{firefox.id}")
      refute has_element?(view, "#channel-subscription-#{chan.id}")
      refute has_element?(view, "#change-subscription-#{change.id}")

      view |> element("#page-search") |> render_change(%{"search" => "unstable"})

      refute has_element?(view, "#package-subscription-#{firefox.id}")
      assert has_element?(view, "#channel-subscription-#{chan.id}")
    end

    test "matches a change by title and number", %{conn: conn} do
      user = register_user!()
      change = change!()
      sub = ChangeSubscription.subscribe!(change.id, nil, actor: user)
      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/inbox/subscriptions")

      view |> element("#page-search") |> render_change(%{"search" => "#{change.number}"})
      assert has_element?(view, "#change-subscription-#{sub.id}")

      view |> element("#page-search") |> render_change(%{"search" => "nomatch"})
      refute has_element?(view, "#change-subscription-#{sub.id}")
      assert render(view) =~ "Nothing matches"
    end

    test "applies the search param from the URL", %{conn: conn} do
      user = register_user!()
      firefox = PackageSubscription.subscribe!(package!("firefox").id, nil, actor: user)
      vim = PackageSubscription.subscribe!(package!("vim").id, nil, actor: user)
      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/inbox/subscriptions?search=firefox")

      assert has_element?(view, "#package-subscription-#{firefox.id}")
      refute has_element?(view, "#package-subscription-#{vim.id}")
      assert has_element?(view, "#page-search-input[value='firefox']")
    end
  end

  test "shows the view toggle with Subscriptions active", %{conn: conn} do
    user = register_user!()
    conn = log_in(conn, user)

    {:ok, view, _html} = live(conn, ~p"/inbox/subscriptions")

    assert has_element?(view, ~s{#view-nav-inbox[href="/inbox"]})
    assert has_element?(view, ~s{#view-nav-subscriptions.is-active[aria-current="page"]})
    refute has_element?(view, "#view-nav-inbox.is-active")
  end
end

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

  describe "time zone preference" do
    test "saves an IANA time zone", %{conn: conn} do
      user = register_via_github!()
      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/account/settings")

      view
      |> form("#settings-form", settings: %{time_zone: "America/New_York"})
      |> render_submit()

      assert Ash.get!(User, user.id, authorize?: false).time_zone == "America/New_York"
      assert view |> element("#time-zone") |> render() =~ ~s(value="America/New_York")
    end

    test "selecting Browser timezone clears the override", %{conn: conn} do
      user =
        register_via_github!()
        |> then(&User.set_time_zone!(&1, %{time_zone: "America/New_York"}, actor: &1))

      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/account/settings")

      view
      |> form("#settings-form", settings: %{time_zone: ""})
      |> render_submit()

      assert is_nil(Ash.get!(User, user.id, authorize?: false).time_zone)
      assert view |> element("#time-zone") |> render() =~ "Browser timezone"
    end

    test "reset button clears the override", %{conn: conn} do
      user =
        register_via_github!()
        |> then(&User.set_time_zone!(&1, %{time_zone: "America/New_York"}, actor: &1))

      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/account/settings")

      view |> element("#reset-time-zone") |> render_click()

      assert is_nil(Ash.get!(User, user.id, authorize?: false).time_zone)
      assert view |> element("#time-zone") |> render() =~ "Browser timezone"
    end
  end

  describe "change auto-subscribe preferences" do
    test "both checkboxes start unchecked", %{conn: conn} do
      user = register_via_github!()
      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/account/settings")

      refute view |> element("#auto-subscribe-authored") |> render() =~ "checked"
      refute view |> element("#auto-subscribe-merged") |> render() =~ "checked"
    end

    test "opting in to authored changes leaves merged off", %{conn: conn} do
      user = register_via_github!()
      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/account/settings")

      view
      |> form("#settings-form",
        settings: %{
          live_ui: "true",
          auto_subscribe_authored_changes: "true",
          auto_subscribe_merged_changes: "false"
        }
      )
      |> render_submit()

      reloaded = Ash.get!(User, user.id, authorize?: false)
      assert reloaded.auto_subscribe_authored_changes
      refute reloaded.auto_subscribe_merged_changes
    end

    test "opting in to merged changes leaves authored off", %{conn: conn} do
      user = register_via_github!()
      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/account/settings")

      view
      |> form("#settings-form",
        settings: %{
          live_ui: "true",
          auto_subscribe_authored_changes: "false",
          auto_subscribe_merged_changes: "true"
        }
      )
      |> render_submit()

      reloaded = Ash.get!(User, user.id, authorize?: false)
      refute reloaded.auto_subscribe_authored_changes
      assert reloaded.auto_subscribe_merged_changes
    end

    test "an opted-in preference renders as checked", %{conn: conn} do
      user = register_via_github!()

      User.set_auto_subscribe!(
        user,
        %{auto_subscribe_authored_changes: true},
        actor: user
      )

      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/account/settings")

      assert view |> element("#auto-subscribe-authored") |> render() =~ "checked"
      refute view |> element("#auto-subscribe-merged") |> render() =~ "checked"
    end
  end

  describe "notifications feed" do
    test "exposes the feed as a copy-on-click icon with a host-relative href", %{conn: conn} do
      user = register_via_github!()
      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/account/settings")

      feed = view |> element("#feed-link") |> render()
      assert feed =~ ~s(href="/feeds/notifications/trk_feed_)
      assert feed =~ ~s(phx-hook="CopyLink")
    end

    test "regenerating invalidates the old URL and reveals the new one", %{conn: conn} do
      user = register_via_github!()
      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/account/settings")
      old_token = Ash.get!(User, user.id, authorize?: false).feed_token
      refute is_nil(old_token)
      refute has_element?(view, "#feed-url")

      view |> element("#regenerate-feed-token") |> render_click()

      assert {:ok, nil} = User.by_feed_token(old_token, authorize?: false)

      new_token = Ash.get!(User, user.id, authorize?: false).feed_token
      refute new_token == old_token

      # The freshly minted URL is revealed with a copy control.
      assert view |> element("#feed-url") |> render() =~ "/feeds/notifications/#{new_token}"
      assert has_element?(view, "#copy-feed-url[phx-hook='CopyLink']")
    end

    test "the regenerate button asks for confirmation first", %{conn: conn} do
      user = register_via_github!()
      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/account/settings")

      assert view |> element("#regenerate-feed-token") |> render() =~ "data-confirm"
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

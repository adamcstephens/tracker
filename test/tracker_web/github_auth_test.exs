defmodule TrackerWeb.GitHubAuthTest do
  use TrackerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    enabled = Application.fetch_env!(:tracker, :github_enabled)
    Application.put_env(:tracker, :github_enabled, false)
    on_exit(fn -> Application.put_env(:tracker, :github_enabled, enabled) end)
    :ok
  end

  test "disabled GitHub rejects authorization and callback routes", %{conn: conn} do
    for path <- ["/auth/user/github", "/auth/user/github/callback?code=unused&state=unused"] do
      response = conn |> recycle() |> get(path)
      assert response.status == 404
      assert get_resp_header(response, "location") == []
    end
  end

  test "disabled GitHub rejects sign-in pages", %{conn: conn} do
    for path <- [~p"/sign-in", ~p"/register", ~p"/reset"] do
      assert conn |> recycle() |> get(path) |> response(404)
    end
  end

  test "disabled GitHub hides sign-in links", %{conn: conn} do
    for path <- [~p"/", ~p"/changes"] do
      {:ok, view, _html} = live(recycle(conn), path)
      refute has_element?(view, "a[href='/sign-in']")
    end
  end

  test "enabled GitHub retains sign-in links and page", %{conn: conn} do
    Application.put_env(:tracker, :github_enabled, true)
    {:ok, view, _html} = live(conn, ~p"/changes")
    assert has_element?(view, "a[href='/sign-in']")

    assert conn |> recycle() |> get(~p"/sign-in") |> html_response(200) =~
             "/auth/user/github"
  end

  test "disabled GitHub uses the local avatar fallback" do
    user = %Tracker.Accounts.User{github_id: 123, github_username: "devuser"}
    html = render_component(&TrackerWeb.Layouts.user_avatar/1, user: user)
    refute html =~ "avatars.githubusercontent.com"
    assert html =~ "app-user__avatar--monogram"
    assert html =~ "D"
  end
end

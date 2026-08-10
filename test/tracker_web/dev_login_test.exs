defmodule TrackerWeb.DevLoginTest do
  use TrackerWeb.ConnCase, async: false

  alias Tracker.Accounts.User

  setup do
    path = Path.join(System.tmp_dir!(), "dev-login-#{System.unique_integer([:positive])}.json")
    Application.put_env(:tracker, :dev_login_file, path)

    on_exit(fn ->
      File.rm(path)
      Application.delete_env(:tracker, :dev_login_file)
    end)

    :ok
  end

  test "a minted token signs the browser in as the dev user", %{conn: conn} do
    user = dev_user!()
    token = Tracker.DevLogin.issue!(user.github_username)

    conn = get(conn, ~p"/dev/login/#{token}")

    assert redirected_to(conn) == ~p"/"
    assert html_response(conn |> recycle() |> get(~p"/account/settings"), 200)
  end

  test "a token that does not match the credentials file is rejected", %{conn: conn} do
    user = dev_user!()
    Tracker.DevLogin.issue!(user.github_username)

    conn = get(conn, ~p"/dev/login/not-the-minted-token")

    assert redirected_to(conn) == ~p"/sign-in"
    assert redirected_to(conn |> recycle() |> get(~p"/account/settings")) == ~p"/sign-in"
  end

  test "a missing credentials file signs nobody in", %{conn: conn} do
    conn = get(conn, ~p"/dev/login/anything")

    assert redirected_to(conn) == ~p"/sign-in"
  end

  test "a token for a user that no longer exists is rejected", %{conn: conn} do
    Tracker.DevLogin.issue!("gone")

    token = Jason.decode!(File.read!(Tracker.DevLogin.path()))["token"]
    conn = get(conn, ~p"/dev/login/#{token}")

    assert redirected_to(conn) == ~p"/sign-in"
  end

  defp dev_user! do
    User
    |> Ash.Changeset.for_create(:register_with_github,
      user_info: %{"id" => System.unique_integer([:positive]), "login" => "devuser"},
      oauth_tokens: %{"access_token" => "dev"}
    )
    |> Ash.create!(authorize?: false)
  end
end

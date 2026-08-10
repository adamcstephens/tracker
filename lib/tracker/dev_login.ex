defmodule Tracker.DevLogin do
  @moduledoc """
  Local sign-in credentials for development.

  GitHub OAuth is the only real strategy, so there is no way to reach
  logged-in pages on a dev box. `mix tracker.dev_user.create` mints a token
  into a gitignored file and the `/dev/login/:token` route — compiled only
  when `:dev_routes` is enabled — trades that token for a session. Nothing
  secret is committed: the token exists only in the local file, and rotating
  it is a re-run of the task.
  """

  alias Tracker.Accounts.User

  @default_path ".dev-login.json"

  @doc "Path of the local credentials file."
  def path, do: Application.get_env(:tracker, :dev_login_file, @default_path)

  @doc "Mints a fresh token for `github_username`, writes it to `path/0` and returns it."
  def issue!(github_username) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    contents = Jason.encode_to_iodata!(%{username: github_username, token: token})

    File.write!(path(), contents)
    File.chmod!(path(), 0o600)

    token
  end

  @doc """
  Resolves a presented token to the dev user, carrying the session token
  `AshAuthentication.Plug.Helpers.store_in_session/2` expects.
  """
  def authenticate(token) do
    with {:ok, contents} <- File.read(path()),
         {:ok, %{"username" => username, "token" => minted}} <- Jason.decode(contents),
         true <- Plug.Crypto.secure_compare(token, minted),
         {:ok, user} <- User.get_by_github_username(username, authorize?: false),
         {:ok, session_token, _claims} <- AshAuthentication.Jwt.token_for_user(user) do
      {:ok, Ash.Resource.put_metadata(user, :token, session_token)}
    else
      _ -> :error
    end
  end
end

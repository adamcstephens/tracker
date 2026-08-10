defmodule Mix.Tasks.Tracker.DevUser.Create do
  @shortdoc "Creates a development user and mints a local sign-in token"
  @moduledoc """
  Creates (or refreshes) a development user and writes a sign-in token to a
  gitignored local file, printing the URL that signs a browser in as them.

  The route that consumes the token only exists when `:dev_routes` is enabled,
  so this is not a way into a production deployment.

  ## Usage

      mix tracker.dev_user.create [--username devuser] [--admin]

  ## Options

    * `--username` - GitHub username to register the dev user under (default `devuser`)
    * `--admin`    - also grant the `:admin` role, which unlocks `/dev` and `/admin`
  """

  use Mix.Task

  alias Tracker.Accounts.User

  @switches [username: :string, admin: :boolean]
  @default_username "devuser"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    opts = parse!(args)

    user =
      opts[:username]
      |> register()
      |> maybe_grant_admin(opts[:admin])

    token = Tracker.DevLogin.issue!(user.github_username)

    Mix.shell().info("""
    Dev user #{user.github_username} (roles: #{Enum.join(user.roles, ", ")})
    Token written to #{Tracker.DevLogin.path()}
    Sign in at #{TrackerWeb.Endpoint.url()}/dev/login/#{token}
    """)
  end

  @doc false
  def parse!(args) do
    {opts, _, _} = OptionParser.parse(args, switches: @switches)

    Keyword.put_new(opts, :username, @default_username)
  end

  defp register(username) do
    User
    |> Ash.Changeset.for_create(:register_with_github,
      user_info: %{"id" => github_id(username), "login" => username},
      oauth_tokens: %{"access_token" => "dev"}
    )
    |> Ash.create!(authorize?: false)
  end

  defp maybe_grant_admin(user, true), do: User.grant_admin!(user, authorize?: false)
  defp maybe_grant_admin(user, _), do: user

  # Negative so a dev user can never collide with, or masquerade as, a real
  # GitHub account; stable so re-runs upsert the same user.
  defp github_id(username), do: -:erlang.phash2(username)
end

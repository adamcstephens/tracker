defmodule Mix.Tasks.Tracker.ApiToken.Revoke do
  @shortdoc "Revokes an API token by JTI"
  @moduledoc """
  Revokes a previously-issued API token by JTI. Authorization comes from
  the actor: token owners revoke their own; admins can additionally
  revoke service-account tokens.

  ## Usage

      mix tracker.api_token.revoke --actor <username> --jti <jti>

  ## Options

    * `--actor` - github username of the actor (required)
    * `--jti`   - JTI of the token to revoke (required)
  """

  use Mix.Task

  alias Mix.Tasks.Tracker.ApiToken.Support
  alias Tracker.Accounts.Token

  @switches [actor: :string, jti: :string]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    opts = parse!(args)
    actor = Support.fetch_user_by_github_username!(opts[:actor])

    case Token.revoke_token_admin(opts[:jti], actor: actor) do
      {:ok, _} ->
        Mix.shell().info("Revoked #{opts[:jti]}")

      {:error, error} ->
        Mix.raise("Failed to revoke token: #{Exception.message(error)}")
    end
  end

  @doc false
  def parse!(args) do
    {opts, _, _} = OptionParser.parse(args, switches: @switches)

    for key <- [:actor, :jti] do
      opts[key] || Mix.raise("missing required --#{key}")
    end

    opts
  end
end
